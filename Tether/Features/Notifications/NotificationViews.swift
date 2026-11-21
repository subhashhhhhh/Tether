//
//  NotificationViews.swift
//  Tether
//
//  Pieces of a phone notification shown on several surfaces: its app's icon, its chat text, hidden text, and its actions.
//

import SwiftUI
import AppKit

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
