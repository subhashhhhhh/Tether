//
//  MessagesView.swift
//  Tether
//
//  SMS messages view for browsing conversation threads and sending replies.
//

import SwiftUI

public struct MessagesView: View {
    @ObservedObject var smsPlugin = TetherService.shared.smsPlugin
    @ObservedObject var service = TetherService.shared
    @State private var selectedThreadId: Int64?
    @State private var composeText = ""
    @State private var searchText = ""

    public init() {}

    public var body: some View {
        NavigationSplitView {
            conversationListView
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let threadId = selectedThreadId, let conversation = smsPlugin.conversations[threadId] {
                threadDetailView(conversation: conversation)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Select a Conversation")
                        .font(.title3.weight(.medium))
                    Text("Choose a message thread from the list to view and reply.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Messages")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: refreshConversations) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh SMS threads from phone")
            }
        }
    }

    private var filteredConversations: [SMSConversation] {
        let all = Array(smsPlugin.conversations.values).sorted(by: { $0.lastDate > $1.lastDate })
        if searchText.isEmpty {
            return all
        }
        return all.filter { conv in
            conv.title.localizedCaseInsensitiveContains(searchText) ||
            conv.snippet.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var conversationListView: some View {
        VStack(spacing: 0) {
            if smsPlugin.conversations.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "message")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No Messages")
                        .font(.headline)
                    Text("Click Refresh to load SMS threads from your connected phone.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Load Messages") {
                        refreshConversations()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                    Spacer()
                }
            } else {
                List(filteredConversations, selection: $selectedThreadId) { conv in
                    NavigationLink(value: conv.threadId) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.accentColor.opacity(0.2))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.accentColor)
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(conv.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)

                                    Spacer()

                                    if let last = conv.lastMessage {
                                        Text(last.formattedTime)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Text(conv.snippet)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            if conv.unreadCount > 0 {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .searchable(text: $searchText, prompt: "Search conversations")
            }
        }
    }

    private func threadDetailView(conversation: SMSConversation) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.headline)
                    Text("\(conversation.messages.count) messages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Message Bubble List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(conversation.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    if let last = conversation.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: conversation.messages.count) { _ in
                    if let last = conversation.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Compose Bar
            HStack(spacing: 10) {
                TextField("Text Message", text: $composeText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        sendMessage(to: conversation)
                    }

                Button(action: {
                    sendMessage(to: conversation)
                }) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func sendMessage(to conversation: SMSConversation) {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let first = service.connectedDevices.first(where: { !$0.value.isDisconnected && $0.value.pairState == .paired }) else {
            return
        }

        smsPlugin.sendSMS(text: text, to: conversation.addresses, threadId: conversation.threadId, connection: first.value)
        composeText = ""
    }

    private func refreshConversations() {
        guard let first = service.connectedDevices.first(where: { !$0.value.isDisconnected && $0.value.pairState == .paired }) else {
            return
        }
        smsPlugin.requestAllConversations(connection: first.value)
    }
}

struct MessageBubble: View {
    let message: SMSMessage

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                Text(message.body)
                    .font(.system(size: 13))
                    .foregroundColor(message.isOutgoing ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isOutgoing ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(14)

                Text(message.formattedTime)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }

            if !message.isOutgoing {
                Spacer(minLength: 60)
            }
        }
    }
}
