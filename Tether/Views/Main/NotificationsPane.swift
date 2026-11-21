//
//  NotificationsPane.swift
//  Tether
//

import SwiftUI

struct NotificationsPane: View {
    let device: DeviceViewModel
    @State private var isConfirmingDismissAll = false

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
            // A list, so a row can be swiped away with two fingers as on the phone.
            List {
                ForEach(groups, id: \.app) { group in
                    // An ordinary row, not a section header: a list pins its
                    // headers and gives them a band of their own.
                    HStack {
                        Text(group.app)
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text(group.items.count, format: .number)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 2)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)

                    ForEach(group.items) { notification in
                        // The row is the window's width, so a swipe carries
                        // it to the edge; its content keeps to the column.
                        NotificationRow(notification: notification, device: device)
                            .frame(maxWidth: 680)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
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
    @FocusState private var isReplyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                if notification.imageIsGlyph, let data = notification.imageData, let image = NSImage(data: data) {
                    // Drawn like Android's status bar: the app's symbol in the text colour.
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: .rect(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("\(notification.appName) icon")
                } else if let data = notification.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(.rect(cornerRadius: 6))
                        .accessibilityLabel("Image from \(notification.appName)")
                } else {
                    // The phone sent no picture. An initial reads better than a blank.
                    Text(notification.appName.prefix(1).uppercased())
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: .rect(cornerRadius: 8, style: .continuous))
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
                    .fixedSize(horizontal: false, vertical: true)
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
