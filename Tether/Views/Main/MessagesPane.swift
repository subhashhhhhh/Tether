//
//  MessagesPane.swift
//  Tether
//

import SwiftUI

struct MessagesPane: View {
    @Bindable var device: DeviceViewModel
    /// Opens on a new message, for design snapshots.
    var startsComposing = false
    @State private var selectedThreadId: Int64?
    @State private var searchText = ""
    @State private var isComposing = false
    /// The conversation to go back to when a new message is cancelled.
    @State private var threadBeforeComposing: Int64?
    /// Stands for the new message in the list's selection.
    private static let draftTag = Int64.min
    /// Who a new message went to, until its conversation shows up to select.
    @State private var pendingRecipient: String?

    private var filteredThreads: [SMSConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return device.smsThreads }
        return device.smsThreads.filter {
            device.title(for: $0).localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
                || $0.snippet.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedThread: SMSConversation? {
        guard let selectedThreadId else { return nil }
        return device.smsThreads.first { $0.id == selectedThreadId }
    }

    var body: some View {
        if device.smsThreads.isEmpty {
            ContentUnavailableView {
                Label("No Conversations", systemImage: "message")
            } description: {
                Text("Text messages sync from \(device.name). Make sure KDE Connect has SMS permission on the phone.")
            } actions: {
                Button("Sync Messages") { device.refreshMessages() }
            }
            .task { device.refreshMessages() }
        } else {
            HSplitView {
                threadList
                    .frame(minWidth: 240, idealWidth: 290, maxWidth: 340)
                Group {
                    if isComposing && selectedThreadId == Self.draftTag {
                        NewConversationView(device: device, onSent: { number in
                            pendingRecipient = number
                            selectPendingThread()
                        }, onCancel: cancelComposing)
                    } else if let selectedThread {
                        ConversationView(thread: selectedThread, device: device)
                            .id(selectedThread.id)
                    } else {
                        ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                // The conversation takes the room; the list keeps its width.
                .layoutPriority(1)
            }
            .onAppear {
                if selectedThreadId == nil { selectedThreadId = device.smsThreads.first?.id }
                if startsComposing { startComposing() }
            }
            .onChange(of: selectedThreadId) {
                guard let selectedThreadId, selectedThreadId != Self.draftTag else { return }
                // Choosing a conversation leaves the new message.
                isComposing = false
                device.openThread(selectedThreadId)
            }
            .onChange(of: device.smsThreads) { selectPendingThread() }
            .onChange(of: device.composeRequests) { startComposing() }
        }
    }

    private func startComposing() {
        if selectedThreadId != Self.draftTag { threadBeforeComposing = selectedThreadId }
        pendingRecipient = nil
        isComposing = true
        selectedThreadId = Self.draftTag
    }

    private func cancelComposing() {
        isComposing = false
        selectedThreadId = threadBeforeComposing ?? device.smsThreads.first?.id
    }

    /// Selects the conversation a new message started, once the phone reports it.
    private func selectPendingThread() {
        guard let pendingRecipient, let key = ContactBook.key(for: pendingRecipient),
              let thread = device.smsThreads.first(where: { $0.addresses.count == 1 && ContactBook.key(for: $0.addresses[0]) == key })
        else { return }
        selectedThreadId = thread.id
        self.pendingRecipient = nil
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedThreadId) {
                // Room for the search pill, which the rows then scroll under.
                Color.clear
                    .frame(height: 38)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .selectionDisabled()
                    .accessibilityHidden(true)
                if isComposing {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.tint)
                            .frame(width: 36, height: 36)
                            .background(.tint.opacity(0.15), in: .circle)
                        Text("New Message")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .tag(Self.draftTag)
                }
                ForEach(filteredThreads) { thread in
                    ThreadRow(thread: thread, device: device)
                        .tag(thread.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 10))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .noTopScrollEdge()
            // The search pill floats over the list, as in Messages: nothing
            // behind it, and rows pass under it as they scroll.
            // Overlaid, not inset: the system draws the toolbar's band and its
            // line over any top inset, and the pill should have only rows
            // behind it. The list's first row is the room it starts in.
            .overlay(alignment: .top) {
                SearchPill(text: $searchText)
                    .padding(.horizontal, 10)
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: SMSConversation
    let device: DeviceViewModel
    /// Increased while the row is selected, when a tinted dot would vanish
    /// into the selection colour.
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .center, spacing: 5) {
                // Inside the row, as in Messages, so it's part of the selection.
                Circle()
                    .fill(backgroundProminence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 7, height: 7)
                    .opacity(thread.unreadCount > 0 ? 1 : 0)
                    .accessibilityLabel("Unread")
                    .accessibilityHidden(thread.unreadCount == 0)
                InitialsAvatar(name: device.title(for: thread), size: 36, photo: device.photo(for: thread),
                               isSenderID: device.isSenderID(thread))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(device.title(for: thread))
                        .fontWeight(thread.unreadCount > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(MessageDate.short(thread.lastDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(thread.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ConversationView: View {
    let thread: SMSConversation
    let device: DeviceViewModel
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The header floats at the top of the window, level with the
            // toolbar's buttons as in Messages, and messages scroll under it.
            MessageList(thread: thread, device: device)
                .floatingHeader(height: 80) {
                    ConversationHeader(thread: thread, device: device)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 60)
                        .padding(.top, 8)
                }
                .ignoresSafeArea(.container, edges: .top)

            MessageComposer(device: device, thread: thread, isFocused: $isComposerFocused) { text, sim in
                guard !thread.addresses.isEmpty else { return }
                device.sendSMS(to: thread.addresses, message: text, threadId: thread.threadId, subId: sim)
            }
        }
    }
}

/// Who the conversation is with, as in Messages: the avatar resting on the
/// top of a glass capsule with the name. Clicking it shows the number.
private struct ConversationHeader: View {
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
private struct MessageList: View {
    let thread: SMSConversation
    let device: DeviceViewModel

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
        for message in thread.messages.sorted(by: { $0.date < $1.date }) {
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
                        MessageBubble(message: message)
                            .padding(.top, startsRun ? 8 : 2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
        .softScrollEdges()
    }
}

/// The message field with the SIM menu and send button, under a conversation
/// or a new message.
private struct MessageComposer: View {
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
        .onChange(of: thread?.threadId, initial: true) { sim = device.defaultSIM(for: thread) }
        .onChange(of: device.sims) { if sim == nil { sim = device.defaultSIM(for: thread) } }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        let text = trimmedDraft
        guard isEnabled, !text.isEmpty else { return }
        send(text, device.sims.count > 1 ? sim : nil)
        draft = ""
        isFocused.wrappedValue = true
    }
}

private struct MessageBubble: View {
    let message: SMSMessage

    private var alignment: Alignment { message.isOutgoing ? .trailing : .leading }

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
            if !message.attachments.isEmpty {
                Label("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                    .font(.caption)
            }
            if !message.body.isEmpty {
                Text(message.body)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(message.isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            message.isOutgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)),
            in: .rect(cornerRadius: 17, style: .continuous)
        )
        .help(message.date.formatted(date: .abbreviated, time: .shortened))
        // A bubble takes at most about two thirds of the conversation's
        // width, so a long text stays readable and its side stays obvious.
        .containerRelativeFrame(.horizontal, alignment: alignment) { width, _ in width * 0.68 }
        .frame(maxWidth: .infinity, alignment: alignment)
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

/// A new message in the conversation pane, as in Messages: a To field that
/// suggests contacts, then the usual composer. Choosing someone you already
/// text shows that conversation, so the reply lands in it.
private struct NewConversationView: View {
    let device: DeviceViewModel
    /// Sent to this number; the pane opens its conversation once the phone has it.
    let onSent: (String) -> Void
    let onCancel: () -> Void

    private struct Recipient: Equatable {
        let name: String?
        let number: String
    }

    @State private var query = ""
    @State private var recipient: Recipient?
    @State private var highlighted = 0
    /// Sent to a new number, shown until its conversation arrives from the phone.
    @State private var sent: [SMSMessage] = []
    @FocusState private var isToFocused: Bool
    @FocusState private var isMessageFocused: Bool

    private var suggestions: [(name: String, number: String)] {
        recipient == nil ? device.contacts.search(query) : []
    }

    /// The text in the To field when it's a phone number.
    private var typedNumber: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return ContactBook.key(for: trimmed) == nil ? nil : trimmed
    }

    /// The one-to-one conversation already held with the recipient.
    private var existingThread: SMSConversation? {
        guard let recipient, let key = ContactBook.key(for: recipient.number) else { return nil }
        return device.smsThreads.first { $0.addresses.count == 1 && ContactBook.key(for: $0.addresses[0]) == key }
    }

    var body: some View {
        VStack(spacing: 0) {
            toField
            Divider()
            ZStack(alignment: .topLeading) {
                if let existingThread {
                    MessageList(thread: existingThread, device: device)
                } else if !sent.isEmpty {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(sent) { MessageBubble(message: $0) }
                        }
                        .padding(16)
                    }
                    .defaultScrollAnchor(.bottom)
                } else {
                    Color.clear
                }
                if !suggestions.isEmpty {
                    suggestionList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MessageComposer(device: device, thread: existingThread, isEnabled: recipient != nil, isFocused: $isMessageFocused) { text, sim in
                guard let recipient else { return }
                device.sendSMS(to: [recipient.number], message: text, threadId: existingThread?.threadId, subId: sim)
                if existingThread == nil {
                    sent.append(SMSMessage(body: text, addresses: [recipient.number], date: .now, type: 2, threadId: 0, read: true))
                }
                onSent(recipient.number)
            }
        }
        .onAppear { isToFocused = true }
        .onChange(of: existingThread?.threadId) { if let id = existingThread?.threadId { device.openThread(id) } }
        .onChange(of: query) { highlighted = 0 }
    }

    private var toField: some View {
        HStack(spacing: 8) {
            Text("To:")
                .foregroundStyle(.secondary)
            if let recipient {
                HStack(spacing: 4) {
                    Text(recipient.name ?? recipient.number)
                        .lineLimit(1)
                    Button("Remove \(recipient.name ?? recipient.number)", systemImage: "xmark.circle.fill") {
                        self.recipient = nil
                        query = ""
                        sent = []
                        isToFocused = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(!sent.isEmpty)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.15), in: .capsule)
                .help(recipient.number)
                if let name = recipient.name {
                    Text(recipient.number)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityHidden(name.isEmpty)
                }
            } else {
                TextField("Name or phone number", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isToFocused)
                    .onSubmit(choose)
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(suggestions.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onExitCommand(perform: onCancel)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, match in
                Button {
                    pick(Recipient(name: match.name, number: match.number))
                } label: {
                    HStack(spacing: 10) {
                        InitialsAvatar(name: match.name, size: 28, photo: device.contacts.contact(for: match.number)?.photo)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.name)
                                .lineLimit(1)
                            Text(match.number)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(index == highlighted ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(6)
        .frame(width: 320)
        .glassPanel(radius: 14)
        .padding(.leading, 46)
        .padding(.top, 4)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    /// Return in the To field: the highlighted contact, or the typed number.
    private func choose() {
        if suggestions.indices.contains(highlighted) {
            let match = suggestions[highlighted]
            pick(Recipient(name: match.name, number: match.number))
        } else if let typedNumber {
            pick(Recipient(name: device.contacts.contact(for: typedNumber)?.name, number: typedNumber))
        }
    }

    private func pick(_ chosen: Recipient) {
        recipient = chosen
        query = ""
        isMessageFocused = true
    }
}

/// Which SIM a message goes out on, for phones with more than one. The phone
/// doesn't say which carrier each SIM is, so they can be named here.
private struct SIMPicker: View {
    let device: DeviceViewModel
    @Binding var selection: Int64?
    @AppStorage(SIMNames.key) private var names = "{}"
    @State private var renaming: PhoneSIM?
    @State private var newName = ""

    var body: some View {
        if device.sims.count > 1 {
            Menu {
                Picker("Send From", selection: $selection) {
                    ForEach(device.sims) { sim in
                        Text("\(label(sim)) · \(sim.networkType)").tag(Optional(sim.id))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Menu("Rename SIM") {
                    ForEach(device.sims) { sim in
                        Button("\(label(sim))…") {
                            newName = SIMNames.name(for: sim, deviceId: device.id, in: names)
                            renaming = sim
                        }
                    }
                }
            } label: {
                Label(selectedLabel, systemImage: "simcard")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose which SIM sends this message")
            .alert("Rename \(renaming.map(label) ?? "SIM")", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let renaming {
                        names = SIMNames.setting(newName, for: renaming, deviceId: device.id, in: names)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Name it after its carrier, for example. Leave it empty to go back to its number.")
            }
        }
    }

    private var selectedLabel: String {
        device.sims.first { $0.id == selection }.map(label) ?? "SIM"
    }

    private func label(_ sim: PhoneSIM) -> String {
        SIMNames.label(for: sim, deviceId: device.id, in: names)
    }
}
