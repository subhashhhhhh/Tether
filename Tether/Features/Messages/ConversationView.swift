//
//  ConversationView.swift
//  Tether
//
//  One conversation: its header, messages, and the field to reply in.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConversationView: View {
    let thread: SMSConversation
    let device: DeviceViewModel
    @FocusState private var isComposerFocused: Bool
    /// The message field's height, which grows with its text, so the last
    /// message always clears it.
    @State private var composerHeight: CGFloat = 56

    var body: some View {
        // The header and the message field float over the conversation with
        // nothing behind them.
        MessageList(thread: thread, device: device, topRoom: 86, bottomRoom: composerHeight)
            .overlay(alignment: .top) {
                HoverBlurBar(edge: .top) {
                    ConversationHeader(thread: thread, device: device)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 60)
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                        // New Message at the conversation's top-leading
                        // corner, where Messages has it.
                        .overlay(alignment: .topLeading) {
                            // Drawn to the toolbar's own measure, a 36 pt glass
                            // circle with its centre 26 pt down, so it reads as
                            // one of the toolbar's buttons. A glass button style
                            // adds padding of its own and comes out larger.
                            Button { device.composeRequests += 1 } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: 36, height: 36)
                                    .glassCircle()
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("n", modifiers: .command)
                            .help("New Message")
                            .accessibilityLabel("New Message")
                            .padding(.leading, 12)
                            .padding(.top, 8)
                        }
                }
            }
            .overlay(alignment: .bottom) {
                // Nothing behind the message field, hovered or not: it floats,
                // and only the header takes a band under the pointer.
                MessageComposer(device: device, thread: thread, isFocused: $isComposerFocused) { text, sim in
                    guard !thread.addresses.isEmpty else { return }
                    device.sendSMS(to: thread.addresses, message: text, threadId: thread.threadId, subId: sim)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
            .ignoresSafeArea(.container, edges: .top)
    }
}

/// Who the conversation is with, as in Messages: the avatar resting on the
/// top of a glass capsule with the name. Clicking it shows the number.
struct ConversationHeader: View {
    let thread: SMSConversation
    let device: DeviceViewModel
    @State private var isShowingDetails = false

    private var title: String { device.title(for: thread) }

    var body: some View {
        Button { isShowingDetails = true } label: {
            // Negative spacing: the avatar just rests on the capsule's top edge.
            VStack(spacing: -7) {
                InitialsAvatar(name: title, size: 40, photo: device.photo(for: thread),
                               isSenderID: device.isSenderID(thread))
                    .zIndex(1)
                HStack(spacing: 5) {
                    Text(title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 6)
                .frame(maxWidth: 300)
                .fixedSize()
                .glassCapsule(interactive: true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show details")
        .accessibilityLabel("\(title), details")
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                InitialsAvatar(name: title, size: 64, photo: device.photo(for: thread),
                               isSenderID: device.isSenderID(thread))
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                ForEach(DeviceViewModel.unique(thread.addresses), id: \.self) { address in
                    HStack(spacing: 8) {
                        Text(address)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Copy \(address)")
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 220)
        }
    }
}

/// A conversation's messages, newest at the bottom. A time stamp opens each
/// stretch of conversation, and a run of messages from one side sits close
/// together.
struct MessageList: View {
    let thread: SMSConversation
    let device: DeviceViewModel
    /// Room left clear at each end for what floats over the conversation.
    var topRoom: CGFloat = 0
    var bottomRoom: CGFloat = 0

    private enum Entry: Identifiable {
        case stamp(Date)
        /// `startsRun` is false for a message that follows one from the same side.
        case message(SMSMessage, startsRun: Bool)

        var id: String {
            switch self {
            case .stamp(let date): "stamp-\(date.timeIntervalSince1970)"
            case .message(let message, _): "message-\(message.id)"
            }
        }
    }

    /// A pause this long starts a new stretch, with its own time stamp.
    private static let stampGap: TimeInterval = 15 * 60

    private var entries: [Entry] {
        var result: [Entry] = []
        var previous: SMSMessage?
        // The plugin keeps each thread sorted oldest first.
        for message in thread.messages {
            let isNewStretch = previous.map {
                message.date.timeIntervalSince($0.date) > Self.stampGap
                    || !Calendar.current.isDate(message.date, inSameDayAs: $0.date)
            } ?? true
            if isNewStretch { result.append(.stamp(message.date)) }
            result.append(.message(message, startsRun: isNewStretch || previous?.isOutgoing != message.isOutgoing))
            previous = message
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Button("Load Earlier Messages") { device.loadEarlierMessages(thread.threadId) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.top, 12)
                ForEach(entries) { entry in
                    switch entry {
                    case .stamp(let date):
                        MessageDate.stamp(date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                    case .message(let message, let startsRun):
                        MessageBubble(message: message, device: device)
                            .padding(.top, startsRun ? 8 : 2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .contentMargins(.top, topRoom, for: .scrollContent)
        .contentMargins(.bottom, bottomRoom, for: .scrollContent)
        .defaultScrollAnchor(.bottom)
        // No system edge effect under the toolbar: the header's own
        // blur-on-hover is the only thing that should appear there.
        .noTopScrollEdge()
    }
}

/// Half-typed messages, so switching conversation or section doesn't lose
/// one. Kept for the session only, and not observed: only the composer that
/// owns a draft reads it, when it appears.
@MainActor
enum MessageDrafts {
    private static var texts: [String: String] = [:]

    static func key(device: DeviceViewModel, thread: SMSConversation?) -> String {
        "\(device.id):\(thread.map { String($0.threadId) } ?? "new")"
    }
    static func text(for key: String) -> String { texts[key] ?? "" }
    static func set(_ text: String, for key: String) { texts[key] = text.isEmpty ? nil : text }
}

/// The message field with the SIM menu and send button, under a conversation
/// or a new message.
struct MessageComposer: View {
    let device: DeviceViewModel
    /// The conversation being replied to, which picks the SIM; nil when new.
    let thread: SMSConversation?
    var isEnabled = true
    var isFocused: FocusState<Bool>.Binding
    /// The text, and the SIM to send it from when the phone has several.
    let send: (String, Int64?) -> Void

    @State private var draft = ""
    @State private var sim: Int64?

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Text Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused(isFocused)
                .onSubmit(submit)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassCapsule()

            // Centred on the send button, which stays level with the field's last line.
            HStack(alignment: .center, spacing: 8) {
                SIMPicker(device: device, selection: $sim)
                Button("Send", systemImage: "arrow.up.circle.fill", action: submit)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title)
                    .foregroundStyle(.tint)
                    .disabled(!isEnabled || trimmedDraft.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.bottom, 3.5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onChange(of: thread?.threadId, initial: true) {
            sim = device.defaultSIM(for: thread)
            draft = MessageDrafts.text(for: draftKey)
        }
        .onChange(of: draft) { MessageDrafts.set(draft, for: draftKey) }
        .onChange(of: device.sims) { if sim == nil { sim = device.defaultSIM(for: thread) } }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draftKey: String { MessageDrafts.key(device: device, thread: thread) }

    private func submit() {
        let text = trimmedDraft
        guard isEnabled, !text.isEmpty else { return }
        send(text, device.sims.count > 1 ? sim : nil)
        draft = ""
        isFocused.wrappedValue = true
    }
}

struct MessageBubble: View {
    let message: SMSMessage
    let device: DeviceViewModel

    private var alignment: Alignment { message.isOutgoing ? .trailing : .leading }

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
            // Pictures sit above the bubble on their own, as in Messages.
            ForEach(message.attachments) { attachment in
                AttachmentView(attachment: attachment) { device.openAttachment(attachment) }
            }
            if !message.body.isEmpty {
                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(message.isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(
                        message.isOutgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)),
                        in: .rect(cornerRadius: 17, style: .continuous)
                    )
            }
        }
        .help(message.date.formatted(date: .abbreviated, time: .shortened))
        // A bubble takes at most about two thirds of the conversation's
        // width, so a long text stays readable and its side stays obvious.
        .containerRelativeFrame(.horizontal, alignment: alignment) { width, _ in width * 0.68 }
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// A text's photo or file: the phone's small preview where there is one,
/// else the file's kind. A click opens it, fetching it from the phone first.
struct AttachmentView: View {
    let attachment: SMSAttachment
    let open: () -> Void

    /// The phone's preview, decoded once per attachment.
    private var thumbnail: NSImage? {
        guard let encoded = attachment.encodedThumbnail, let data = Data(base64Encoded: encoded) else { return nil }
        return ImageCache.image(data, key: attachment.uniqueIdentifier, maxPixels: 400)
    }

    private var kind: String {
        UTType(mimeType: attachment.mimeType)?.localizedDescription?.capitalized ?? "Attachment"
    }

    var body: some View {
        Button(action: open) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 200, height: 200)
                    .clipShape(.rect(cornerRadius: 17, style: .continuous))
            } else {
                Label(kind, systemImage: attachment.mimeType.hasPrefix("audio") ? "waveform" : "doc")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 17, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .help(attachment.localURL == nil ? "Get from phone and open" : "Open")
        .accessibilityLabel(kind)
    }
}

enum MessageDate {
    /// The stamp over a stretch of conversation: the day in bold, then the
    /// time, as in Messages ("Today 3:19 PM").
    static func stamp(_ date: Date) -> Text {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            day = date.formatted(.dateTime.weekday(.wide))
        } else {
            day = date.formatted(date: .abbreviated, time: .omitted)
        }
        return Text(day).fontWeight(.semibold) + Text(" " + date.formatted(date: .omitted, time: .shortened))
    }

    /// Time for today, weekday within a week, short date otherwise (like Messages).
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
