//
//  NotificationsPane.swift
//  Tether
//

import SwiftUI

struct NotificationsPane: View {
    let device: DeviceViewModel
    @State private var isConfirmingDismissAll = false
    /// The list fills the window, so it scrolls anywhere in it and a swiped
    /// card slides to the edge. The cards keep a margin rather than a fixed
    /// width, so Dismiss is uncovered right behind a card.
    static let rowInsets = EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)

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
                        NotificationAppIcon(appName: group.app, glyph: device.appGlyphs[group.app], size: 24)
                        Text(group.app)
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text(group.items.count, format: .number)
                            .foregroundStyle(.secondary)
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
            // No toolbar band over the narrower list's top.
            .noTopScrollEdge()
            .animation(.default, value: device.notifications)
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
                }
                Text(notification.title.isEmpty ? notification.appName : notification.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(notification.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !notification.text.isEmpty {
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

/// Copies a verification code and says so for a moment.
/// The app a notification came from: its status-bar glyph from the phone,
/// drawn in the text colour as Android draws it, or its initial until the
/// phone has sent one. The phone never sends an app's coloured icon.
struct NotificationAppIcon: View {
    let appName: String
    let glyph: Data?
    var size: CGFloat = 20

    private static let images = NSCache<NSData, NSImage>()

    /// Decoded once per picture, not on every redraw.
    static func image(_ data: Data) -> NSImage? {
        if let cached = images.object(forKey: data as NSData) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: data as NSData)
        return image
    }

    var body: some View {
        Group {
            if let glyph, let image = Self.image(glyph) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
            } else {
                Text(appName.prefix(1).uppercased())
                    .font(.system(size: size * 0.52, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .background(.quaternary, in: .rect(cornerRadius: size * 0.26, style: .continuous))
        .accessibilityHidden(true)
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
