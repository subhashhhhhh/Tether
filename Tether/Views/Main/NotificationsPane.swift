//
//  NotificationsPane.swift
//  Tether
//

import SwiftUI

struct NotificationsPane: View {
    let device: DeviceViewModel

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
            GlassPage {
                ForEach(groups, id: \.app) { group in
                    GlassSection(group.app) {
                        Text(group.items.count, format: .number)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } content: {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, notification in
                            if index > 0 { Divider().padding(.leading, 16) }
                            NotificationRow(notification: notification, device: device)
                        }
                    }
                }
            }
            .animation(.default, value: device.notifications)
            .toolbar {
                if device.notifications.contains(where: \.isDismissable) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear All", systemImage: "xmark.circle") {
                            for notification in device.notifications where notification.isDismissable {
                                device.dismiss(notification)
                            }
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
            } else if notification.code != nil || notification.replyId != nil || notification.isDismissable {
                HStack(spacing: 8) {
                    if let code = notification.code {
                        CopyCodeButton(code: code)
                    }
                    if notification.replyId != nil {
                        Button("Reply") { isReplying = true }
                    }
                    if notification.isDismissable {
                        Button("Dismiss") { device.dismiss(notification) }
                    }
                }
                .controlSize(.small)
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
