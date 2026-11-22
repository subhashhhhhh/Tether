//
//  NewMessageView.swift
//  Tether
//
//  A new message: who it's to, and the SIM it goes from.
//

import SwiftUI
import AppKit

/// A new message in the conversation pane, as in Messages: a To field that
/// suggests contacts, then the usual composer. Choosing someone you already
/// text shows that conversation, so the reply lands in it.
struct NewConversationView: View {
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
                            ForEach(sent) { MessageBubble(message: $0, device: device) }
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
struct SIMPicker: View {
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
            .menuStyle(.button)
            .buttonStyle(.borderless)
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
