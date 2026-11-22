//
//  MessagesPane.swift
//  Tether
//

import SwiftUI
import UniformTypeIdentifiers

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
    /// True while the empty page is waiting on the phone's conversations.
    @State private var isSyncing = true
    @State private var syncAttempt = 0
    @Environment(\.isSidebarCollapsed) private var isSidebarCollapsed

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
            // Says that it's asking the phone, rather than claiming there are
            // no conversations while the first sync is still on its way.
            ContentUnavailableView {
                if isSyncing {
                    Label {
                        Text("Syncing Messages…")
                    } icon: {
                        ProgressView()
                            .controlSize(.large)
                    }
                } else {
                    Label("No Conversations", systemImage: "message")
                }
            } description: {
                Text(isSyncing
                     ? "Getting conversations from \(device.name)."
                     : "Nothing came back from \(device.name). Make sure KDE Connect has SMS permission on the phone.")
            } actions: {
                if !isSyncing {
                    Button("Sync Messages") { syncAttempt += 1 }
                }
            }
            .task(id: syncAttempt) {
                isSyncing = true
                device.refreshMessages()
                // The phone doesn't say when it has nothing to send; after a
                // while with no conversations, stop waiting and say so.
                try? await Task.sleep(for: .seconds(12))
                if !Task.isCancelled { isSyncing = false }
            }
        } else {
            // The divider stays where it was left, across visits and launches.
            SavedSplitView(autosaveName: "TetherMessagesSplit", leadingWidths: 240...340, trailingMinimumWidth: 320) {
                threadList
            } trailing: {
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
            // Each pane decides for itself how far up it reaches.
            .ignoresSafeArea(.container, edges: .top)
            .onAppear {
                // Catches up on anything missed while the phone was away.
                device.refreshMessages()
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

    /// The list runs up into the toolbar's height, where its search pill
    /// sits level with the toolbar buttons. With the sidebar hidden those
    /// buttons are in that corner, so the list stays below them.
    private var searchTop: CGFloat { isSidebarCollapsed ? 0 : 8 }

    private var threadList: some View {
        // Selection is drawn here rather than by the list: a list's own is a
        // darker blue, and turns grey when the message field has focus.
        // Messages keeps the lighter accent colour on, always.
        List {
            // Room for the search pill, which the rows then scroll under.
            Color.clear
                .frame(height: searchTop + 40)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .accessibilityHidden(true)
            if isComposing {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.2), in: .circle)
                    Text("New Message")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.leading, 10)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 10))
                .listRowBackground(SelectionBackground(isSelected: true))
                .listRowSeparator(.hidden)
            }
            ForEach(filteredThreads) { thread in
                let isSelected = thread.id == selectedThreadId
                ThreadRow(thread: thread, device: device, isSelected: isSelected)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 10))
                    .listRowBackground(SelectionBackground(isSelected: isSelected))
                    .listRowSeparator(isSelected ? .hidden : .automatic)
                    .contentShape(.rect)
                    .onTapGesture { selectedThreadId = thread.id }
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .noTopScrollEdge()
        .modifier(FocusedOnAppear())
        .onMoveCommand { direction in
            let ids = filteredThreads.map(\.id)
            guard let current = selectedThreadId.flatMap(ids.firstIndex) else { return }
            switch direction {
            case .up where current > 0: selectedThreadId = ids[current - 1]
            case .down where current < ids.count - 1: selectedThreadId = ids[current + 1]
            default: break
            }
        }
        // Overlaid, not inset: the system draws the toolbar's band and its
        // line over any top inset, and the pill should have only rows
        // behind it, as in Messages.
        .overlay(alignment: .top) {
            SearchPill(text: $searchText)
                .padding(.horizontal, 10)
                .padding(.top, searchTop)
        }
        .ignoresSafeArea(.container, edges: isSidebarCollapsed ? [] : .top)
    }
}

/// The list has focus when the page opens, so arrow keys move through it.
/// Its own focus state: the list is a separate SwiftUI hierarchy inside the
/// split view, which a focus state in the page can't reach.
private struct FocusedOnAppear: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { isFocused = true }
    }
}

/// The selected conversation's fill: the accent colour, inset and rounded.
private struct SelectionBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            .padding(.horizontal, 8)
    }
}

private struct ThreadRow: View {
    let thread: SMSConversation
    let device: DeviceViewModel
    let isSelected: Bool

    private var secondary: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        // Centred: with a three-line row the avatar and its dot sit in the
        // middle of it, as in Messages, not at the top.
        HStack(alignment: .center, spacing: 10) {
            // The list insets a row 8 pt inside the selection (measured in a
            // render); 10 more puts the avatar 18 pt in, as in Messages. The
            // dot is drawn in that margin and takes no room of its own.
            InitialsAvatar(name: device.title(for: thread), size: 36, photo: device.photo(for: thread),
                           isSenderID: device.isSenderID(thread))
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                        .frame(width: 8, height: 8)
                        .offset(x: -4)
                        .opacity(thread.unreadCount > 0 ? 1 : 0)
                        .accessibilityLabel("Unread")
                        .accessibilityHidden(thread.unreadCount == 0)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(device.title(for: thread))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(MessageDate.short(thread.lastDate))
                        .font(.caption)
                        .foregroundStyle(secondary)
                }
                Text(thread.snippet)
                    .font(.subheadline)
                    .foregroundStyle(secondary)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.vertical, 6)
    }
}

