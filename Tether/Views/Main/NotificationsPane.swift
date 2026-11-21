//
//  NotificationsPane.swift
//  Tether
//

import SwiftUI

struct NotificationsPane: View {
    let device: DeviceViewModel
    @State private var isConfirmingDismissAll = false
    /// Rows have no insets of their own: the inset list style already keeps
    /// each row in from the sides, so a row is exactly its card, and a swipe
    /// uncovers Dismiss right at the card's edge. (`contentMargins` would
    /// move the margin, but List ignores it.)
    static let rowInsets = EdgeInsets()

    /// Notifications grouped by app, the app with the newest one first.
    private var groups: [(app: String, items: [PhoneNotification])] {
        let byApp = Dictionary(grouping: device.notifications, by: \.appName)
        return byApp
            .map { (app: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { ($0.items.first?.date ?? .distantPast) > ($1.items.first?.date ?? .distantPast) }
    }

    var body: some View {
        if device.notifications.isEmpty {
            ContentUnavailableView(
                "No Notifications",
                systemImage: "bell.slash",
                description: Text("Notifications on \(device.name) show up here and in Notification Center. Turn on notification sync in KDE Connect on your phone if they don't.")
            )
        } else {
            // A list, so a row can be swiped away with two fingers as on the
            // phone. Each app is one card: its icon and name on top, then its
            // notifications, so it's plain which app a row belongs to and
            // where that app's rows end.
            List {
                ForEach(groups, id: \.app) { group in
                    HStack(spacing: 8) {
                        NotificationAppIcon(appName: group.app, glyph: group.items.first.flatMap(device.glyph(for:)), size: 24)
                        Text(group.app)
                            .font(.title2.weight(.semibold))
                        Text(group.items.count, format: .number)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 20)
                    .padding(.bottom, 6)
                    .listRowInsets(Self.rowInsets)
                    .listRowSeparator(.hidden)

                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, notification in
                        NotificationRow(notification: notification, device: device)
                            .listRowInsets(Self.rowInsets)
                            .listRowSeparator(.hidden)
                            // The card is part of the row, not the row's
                            // background, so a swipe moves the whole card.
                            .background(GroupCardBackground(isFirst: index == 0, isLast: index == group.items.count - 1,
                                                            maxWidth: .infinity, margin: 0))
                            .listRowBackground(Color.clear)
                            .overlay(alignment: .top) {
                                if index > 0 {
                                    Divider()
                                        .padding(.horizontal, 16)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if notification.isDismissable {
                                    Button("Dismiss", systemImage: "xmark", role: .destructive) {
                                        device.dismiss(notification)
                                    }
                                }
                            }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .noTopScrollEdge()
            .readableCardList()
            // Animates on which notifications there are, without comparing
            // every notification's text and picture on each redraw.
            .animation(.default, value: device.notifications.map(\.id))
            // It clears the phone's notification shade too, so it asks first.
            .confirmationDialog("Dismiss all notifications on \(device.name)?", isPresented: $isConfirmingDismissAll) {
                Button("Dismiss All", role: .destructive) {
                    for notification in device.notifications where notification.isDismissable {
                        device.dismiss(notification)
                    }
                }
            } message: {
                Text("They're dismissed on the phone as well.")
            }
            .toolbar {
                if device.notifications.contains(where: \.isDismissable) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isConfirmingDismissAll = true
                        } label: {
                            Label("Dismiss All", systemImage: "xmark.circle")
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 4)
                        }
                        .help("Dismiss every notification on \(device.name)")
                    }
                }
            }
        }
    }
}

private struct NotificationRow: View {
    let notification: PhoneNotification
    let device: DeviceViewModel

    @State private var isReplying = false
    @State private var reply = ""
    @State private var isExpanded = false
    @FocusState private var isReplyFocused: Bool

    /// A long message is cut to a few lines until asked for, so one
    /// notification can't push the rest of the page out of sight.
    private var isLong: Bool {
        notification.text.count > 280 || notification.text.filter(\.isNewline).count > 3
    }

    /// A picture of who it's from. The app's own glyph is on the group, not here.
    private var photo: NSImage? {
        guard !notification.imageIsGlyph, let data = notification.imageData else { return nil }
        return NotificationAppIcon.image(data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                if let photo {
                    Image(nsImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(.circle)
                        .accessibilityHidden(true)
                } else if notification.isFromSystem, notification.imageIsGlyph {
                    // Android's own icon for this notification: battery, Wi-Fi.
                    NotificationAppIcon(appName: notification.appName, glyph: notification.imageData, size: 28)
                }
                Text(notification.title.isEmpty ? notification.appName : notification.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(notification.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if notification.isRedacted {
                RedactedText()
            } else if !notification.conversation.isEmpty {
                ConversationText(notification: notification)
                    .lineLimit(isLong && !isExpanded ? 4 : nil)
                if isLong {
                    Button(isExpanded ? "Show Less" : "Show More") { isExpanded.toggle() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            } else if !notification.text.isEmpty {
                // The message is the content, so it isn't greyed out.
                Text(notification.text)
                    .textSelection(.enabled)
                    .lineLimit(isLong && !isExpanded ? 4 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if isLong {
                    Button(isExpanded ? "Show Less" : "Show More") { isExpanded.toggle() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }

            if isReplying {
                HStack(spacing: 8) {
                    TextField("Reply to \(notification.title.isEmpty ? notification.appName : notification.title)", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .focused($isReplyFocused)
                        .onSubmit(sendReply)
                    Button("Cancel") { isReplying = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Send", action: sendReply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 6)
                .onAppear { isReplyFocused = true }
            } else {
                NotificationQuickActions(notification: notification, device: device) { isReplying = true }
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .animation(.default, value: isExpanded)
        .contextMenu {
            if let code = notification.code {
                Button("Copy Code \(code)") { NotificationPlugin.copyToPasteboard(code) }
            }
            if notification.replyId != nil {
                Button("Reply") { isReplying = true }
            }
            if notification.isDismissable {
                Button("Dismiss on Phone") { device.dismiss(notification) }
            }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(notification.text, forType: .string)
            }
        }
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        device.reply(to: notification, text: text)
        reply = ""
        isReplying = false
    }
}

/// A chat's recent messages, each sender's name in bold where it changes,
/// as the phone shows them. The first sender is the row's title.
struct ConversationText: View {
    let notification: PhoneNotification

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        var previous = notification.title
        for (index, line) in notification.conversation.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            if !line.sender.isEmpty, line.sender != previous {
                var sender = AttributedString(line.sender + ": ")
                sender.font = .body.weight(.semibold)
                result += sender
                previous = line.sender
            }
            result += AttributedString(line.content)
        }
        return result
    }
}

/// What Android 15 shows apps like KDE Connect instead of a notification it
/// thinks is sensitive, with what can be done about it.
struct RedactedText: View {
    @State private var isShowingHelp = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Android hid this notification's text")
                .foregroundStyle(.secondary)
            Button("Why?", systemImage: "info.circle") { isShowingHelp.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .popover(isPresented: $isShowingHelp, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hidden by Android")
                            .font(.headline)
                        Text("Android 15 hides notifications it thinks are sensitive, like sign-in codes, from apps such as KDE Connect. It can be allowed from a computer with adb:")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("adb shell appops set org.kde.kdeconnect_tp RECEIVE_SENSITIVE_NOTIFICATIONS allow")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(width: 320, alignment: .leading)
                }
        }
    }
}

/// Copies a verification code and says so for a moment.
/// The app a notification came from: its status-bar glyph from the phone,
/// drawn in the text colour as Android draws it, or its initial until the
/// phone has sent one. The phone never sends an app's coloured icon.
struct NotificationAppIcon: View {
    let appName: String
    let glyph: Data?
    var size: CGFloat = 20

    /// Decoded once per picture, not on every redraw.
    static func image(_ data: Data) -> NSImage? { ImageCache.image(data, maxPixels: 96) }

    /// Nothing until the phone has sent the app's glyph: the name beside it
    /// already says which app it is.
    var body: some View {
        if let glyph, let image = Self.image(glyph) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .padding(size * 0.2)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.quaternary, in: .rect(cornerRadius: size * 0.26, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// What can be done about a notification, as small buttons: copy its code,
/// reply, the buttons the notification has on the phone, and dismiss.
struct NotificationQuickActions: View {
    let notification: PhoneNotification
    let device: DeviceViewModel
    /// Opens the reply field, where the surface has one.
    var onReply: (() -> Void)?

    var body: some View {
        if notification.code != nil || !notification.actions.isEmpty || notification.isDismissable
            || (notification.replyId != nil && onReply != nil) {
            HStack(spacing: 8) {
                if let code = notification.code {
                    CopyCodeButton(code: code)
                }
                if notification.replyId != nil, let onReply {
                    Button("Reply", action: onReply)
                }
                ForEach(notification.actions, id: \.self) { action in
                    Button(action) { device.perform(action, on: notification) }
                }
                if notification.isDismissable {
                    Button("Dismiss") { device.dismiss(notification) }
                }
            }
            .controlSize(.small)
        }
    }
}

struct CopyCodeButton: View {
    let code: String
    /// Just the code, where there's no room for "Copy Code".
    var isCompact = false
    @State private var copied = false

    var body: some View {
        Button {
            NotificationPlugin.copyToPasteboard(code)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : (isCompact ? code : "Copy Code \(code)"), systemImage: copied ? "checkmark" : "doc.on.doc")
                .monospacedDigit()
        }
        .accessibilityLabel(copied ? "Copied" : "Copy code \(code.map(String.init).joined(separator: " "))")
        .help("Copy the code \(code)")
    }
}

#if DEBUG
#Preview {
    NotificationsPane(device: .mockConnectedPhone())
        .frame(width: 640, height: 520)
}
#endif
