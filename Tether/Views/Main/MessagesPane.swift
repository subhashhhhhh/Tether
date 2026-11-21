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
            HStack(spacing: 0) {
                threadList
                    .frame(width: 280)
                Divider()
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
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
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct ThreadRow: View {
    let thread: SMSConversation
    let device: DeviceViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            InitialsAvatar(name: device.title(for: thread), size: 36, photo: device.photo(for: thread))

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
                HStack(alignment: .top) {
                    Text(thread.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if thread.unreadCount > 0 {
                        Circle()
                            .fill(.tint)
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                            .accessibilityLabel("Unread")
                    }
                }
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
            VStack(spacing: 4) {
                InitialsAvatar(name: device.title(for: thread), size: 36, photo: device.photo(for: thread))
                Text(device.title(for: thread))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            MessageList(thread: thread, device: device)

            MessageComposer(device: device, thread: thread, isFocused: $isComposerFocused) { text, sim in
                guard !thread.addresses.isEmpty else { return }
                device.sendSMS(to: thread.addresses, message: text, threadId: thread.threadId, subId: sim)
            }
        }
    }
}

/// A conversation's messages by day, newest at the bottom.
private struct MessageList: View {
    let thread: SMSConversation
    let device: DeviceViewModel

    private struct DayGroup: Identifiable {
        let day: Date
        var messages: [SMSMessage]
        var id: Date { day }
    }

    /// Messages split into calendar days, in order.
    private var days: [DayGroup] {
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for message in thread.messages.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: message.date)
            if result.last?.day == day {
                result[result.count - 1].messages.append(message)
            } else {
                result.append(DayGroup(day: day, messages: [message]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                Button("Load Earlier Messages") { device.loadEarlierMessages(thread.threadId) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.top, 12)
                ForEach(days) { group in
                    Text(group.day.formatted(date: .complete, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                    ForEach(group.messages) { message in
                        MessageBubble(message: message)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
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

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 80) }

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

            if !message.isOutgoing { Spacer(minLength: 80) }
        }
    }
}

enum MessageDate {
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
