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

#if DEBUG
#Preview {
    NotificationsPane(device: .mockConnectedPhone())
        .frame(width: 640, height: 520)
}
#endif
