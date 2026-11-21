//
//  SMSPlugin.swift
//  Tether
//
//  Plugin for viewing and replying to SMS conversations from macOS.
//

import AppKit
import Foundation
import Combine

public final class SMSPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {
    public static let messagesType = PacketType.smsMessages
    public static let attachmentFileType = PacketType.smsAttachmentFile
    public static let requestType = PacketType.smsRequest
    public static let requestConversationsType = PacketType.smsRequestConversations
    public static let requestConversationType = PacketType.smsRequestConversation
    public static let requestAttachmentType = PacketType.smsRequestAttachment

    public var supportedPacketTypes: [String] {
        [Self.messagesType, Self.attachmentFileType]
    }

    /// By device, then thread: thread IDs are only unique on one phone, and
    /// with two phones a reply must reach the right one.
    @Published public private(set) var conversations: [String: [Int64: SMSConversation]] = [:] {
        didSet { revision &+= 1 }
    }
    /// Changes whenever conversations do, so a reader can skip re-sorting
    /// when nothing changed.
    public private(set) var revision = 0

    public init() {}

    /// Asks on every connect: the phone sends new messages as they arrive
    /// only once it has been asked for messages since it connected, and the
    /// answer fills the unread counts. A swapped connection keeps the phone's
    /// side as it was, so that needs nothing (see onConnectionReplaced).
    public func onConnected(connection: DeviceConnection) {
        requestAllConversations(connection: connection)
    }

    public func onDisconnected(connection: DeviceConnection) {}

    /// Its state belongs to the device, not the connection, and is kept.
    public func onConnectionReplaced(old: DeviceConnection, new: DeviceConnection) {}

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        if packet.type == Self.messagesType, let deviceId = connection.peerDeviceInfo?.deviceId {
            handleBatchMessages(packet: packet, deviceId: deviceId)
        }
    }

    /// Where attachments are kept once fetched, so each is fetched once.
    nonisolated static let attachmentDirectory: URL = {
        let caches = URL.cachesDirectory
        return caches.appendingPathComponent("TetherAttachments", isDirectory: true)
    }()

    /// The file for an attachment; `uniqueIdentifier` comes from the phone, so
    /// it's only ever used sanitised.
    nonisolated static func attachmentURL(for uniqueIdentifier: String) -> URL {
        attachmentDirectory.appendingPathComponent(SafeFilename.sanitize(uniqueIdentifier, fallback: "attachment"))
    }

    /// Attachments clicked before they'd arrived, opened when they do.
    private var attachmentsToOpen: Set<String> = []

    public func handlePayload(connection: DeviceConnection, packet: NetworkPacket, fileURL payloadURL: URL) {
        guard packet.type == Self.attachmentFileType, let deviceId = connection.peerDeviceInfo?.deviceId,
              let identifier = packet.string(for: "filename"), !identifier.isEmpty else { return }
        // The phone names the attachment only by its identifier, not its
        // conversation, so every conversation of this phone is searched.
        let fileURL = Self.attachmentURL(for: identifier)
        do {
            try? FileManager.default.createDirectory(at: Self.attachmentDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: payloadURL, to: fileURL)
        } catch {
            TetherLog("[SMSPlugin] Failed to save an attachment: \(error)")
            return
        }
        DispatchQueue.main.async {
            self.conversations[deviceId] = Self.attaching(fileURL, to: identifier, in: self.conversations[deviceId] ?? [:])
            if self.attachmentsToOpen.remove(identifier) != nil { NSWorkspace.shared.open(fileURL) }
        }
    }

    /// Points every attachment with this identifier, in any conversation,
    /// at the fetched file.
    static func attaching(_ fileURL: URL, to identifier: String,
                          in threads: [Int64: SMSConversation]) -> [Int64: SMSConversation] {
        var threads = threads
        for (threadId, var conversation) in threads {
            var changed = false
            for m in conversation.messages.indices {
                for a in conversation.messages[m].attachments.indices
                where conversation.messages[m].attachments[a].uniqueIdentifier == identifier {
                    conversation.messages[m].attachments[a].localURL = fileURL
                    changed = true
                }
            }
            if changed { threads[threadId] = conversation }
        }
        return threads
    }

    /// Opens an attachment, fetching it from the phone first if needed.
    public func openAttachment(_ attachment: SMSAttachment, connection: DeviceConnection?) {
        let fileURL = Self.attachmentURL(for: attachment.uniqueIdentifier)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.open(fileURL)
        } else if let connection {
            attachmentsToOpen.insert(attachment.uniqueIdentifier)
            requestAttachment(partId: attachment.partId, uniqueIdentifier: attachment.uniqueIdentifier, connection: connection)
        }
    }

    // MARK: - Actions

    public func requestAllConversations(connection: DeviceConnection) {
        let packet = NetworkPacket(type: Self.requestConversationsType)
        connection.send(packet: packet)
        TetherLog("[SMSPlugin] Requested all SMS conversations")
    }

    /// Asks for a thread's messages. A negative `rangeStartTimestamp` means
    /// the newest ones; otherwise the phone returns messages older than it
    /// (milliseconds since 1970). 0 asked for messages from before 1970, which
    /// is why only each thread's latest message ever showed.
    public func requestConversation(threadId: Int64, rangeStartTimestamp: Int64 = -1, numberToRequest: Int = 50, connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: Self.requestConversationType,
            body: [
                "threadID": AnyCodable(threadId),
                "rangeStartTimestamp": AnyCodable(rangeStartTimestamp),
                "numberToRequest": AnyCodable(numberToRequest)
            ]
        )
        connection.send(packet: packet)
        TetherLog("[SMSPlugin] Requested conversation \(threadId)")
    }

    /// The page before the oldest message loaded, growing like desktop KDE
    /// Connect's: as many as are already loaded, at least 50.
    public func requestEarlierMessages(threadId: Int64, connection: DeviceConnection) {
        let deviceId = connection.peerDeviceInfo?.deviceId ?? ""
        let loaded = conversations[deviceId]?[threadId]?.messages ?? []
        guard let page = Self.earlierPage(before: loaded) else {
            requestConversation(threadId: threadId, connection: connection)
            return
        }
        requestConversation(threadId: threadId, rangeStartTimestamp: page.start, numberToRequest: page.count, connection: connection)
    }

    /// The page before the oldest loaded message: starting there, as many as
    /// are loaded, at least 50. Nil when nothing is loaded yet.
    static func earlierPage(before loaded: [SMSMessage]) -> (start: Int64, count: Int)? {
        guard let oldest = loaded.map(\.date).min() else { return nil }
        return (Int64(oldest.timeIntervalSince1970 * 1000), max(50, loaded.count))
    }

    public func requestAttachment(partId: Int64, uniqueIdentifier: String, connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: Self.requestAttachmentType,
            body: [
                "part_id": AnyCodable(partId),
                "unique_identifier": AnyCodable(uniqueIdentifier)
            ]
        )
        connection.send(packet: packet)
    }

    /// Sends from SIM `subId` when given, else the one the conversation uses.
    public func sendSMS(text: String, to addresses: [String], threadId: Int64? = nil, subId: Int64? = nil, connection: DeviceConnection) {
        guard !text.isEmpty, !addresses.isEmpty else { return }

        let addressList = addresses.map { ["address": AnyCodable($0)] }
        var body: [String: AnyCodable] = [
            "version": AnyCodable(2),
            "addresses": AnyCodable(addressList),
            "messageBody": AnyCodable(text)
        ]
        // Reply from the SIM the conversation uses, as desktop KDE Connect
        // does. Without it the phone sends from its default SMS SIM, and a
        // dual-SIM phone set to "Ask every time" has none, so nothing is sent.
        // Only a SIM the phone reports now counts, and only when it has more
        // than one: old messages can name a SIM that has since been replaced,
        // and the phone silently drops a message for a SIM it doesn't have.
        let activeSIMs = connection.peerDeviceInfo
            .flatMap { TetherService.shared.connectivityReportPlugin.subscriptions[$0.deviceId] }
            .map { Set($0.keys) } ?? []
        let deviceId = connection.peerDeviceInfo?.deviceId ?? ""
        let conversationSubId = threadId.flatMap { conversations[deviceId]?[$0]?.messages.last(where: { $0.subId != nil })?.subId }
        let chosenSubId = (subId ?? conversationSubId).flatMap { activeSIMs.count > 1 && activeSIMs.contains($0) ? $0 : nil }
        if let chosenSubId {
            body["subID"] = AnyCodable(chosenSubId)
        }
        let packet = NetworkPacket(type: Self.requestType, body: body)
        connection.send(packet: packet)
        TetherLog("[SMSPlugin] Dispatched SMS to \(addresses.count) recipient(s), SIM \(chosenSubId.map(String.init) ?? "default")"
            + " (asked for \((subId ?? conversationSubId).map(String.init) ?? "none"), phone has \(activeSIMs.sorted()))")

        // Optimistically add to local messages
        if let targetThreadId = threadId {
            let optimisticMessage = SMSMessage(
                id: UUID(),
                event: 1,
                body: text,
                addresses: addresses,
                date: Date(),
                type: 2, // outgoing
                threadId: targetThreadId,
                read: true
            )
            DispatchQueue.main.async {
                if var conv = self.conversations[deviceId]?[targetThreadId] {
                    conv.messages.append(optimisticMessage)
                    self.conversations[deviceId, default: [:]][targetThreadId] = conv
                }
            }
        }
    }

    // MARK: - Internal Message Parsing

    /// Parsing, and checking the disk for fetched attachments, happens here
    /// rather than on the main thread, where packets are delivered.
    nonisolated private static let parseQueue = DispatchQueue(label: "com.subhashh.tether.sms-parse", qos: .userInitiated)

    private func handleBatchMessages(packet: NetworkPacket, deviceId: String) {
        let rawMessages = packet.objectArray(for: "messages")
        guard !rawMessages.isEmpty else { return }
        Self.parseQueue.async { self.merge(Self.parse(rawMessages), deviceId: deviceId) }
    }

    nonisolated private static func parse(_ rawMessages: [[String: Any]]) -> [SMSMessage] {
        var parsedMessages: [SMSMessage] = []
        for raw in rawMessages {
            if var msg = SMSMessage.from(dictionary: raw) {
                for index in msg.attachments.indices {
                    let url = Self.attachmentURL(for: msg.attachments[index].uniqueIdentifier)
                    if FileManager.default.fileExists(atPath: url.path) { msg.attachments[index].localURL = url }
                }
                parsedMessages.append(msg)
            }
        }
        return parsedMessages
    }

    private func merge(_ parsedMessages: [SMSMessage], deviceId: String) {
        guard !parsedMessages.isEmpty else { return }
        let byThread = Dictionary(grouping: parsedMessages, by: \.threadId)
        DispatchQueue.main.async {
            // Each thread merged once per batch and published once.
            var threads = self.conversations[deviceId] ?? [:]
            for (threadId, incoming) in byThread {
                var conversation = threads[threadId] ?? SMSConversation(threadId: threadId, addresses: incoming[0].addresses)
                if conversation.addresses.isEmpty, let addresses = incoming.first(where: { !$0.addresses.isEmpty })?.addresses {
                    conversation.addresses = addresses
                }
                conversation.messages = Self.merging(incoming, into: conversation.messages)
                threads[threadId] = conversation
            }
            self.conversations[deviceId] = threads
            TetherLog("[SMSPlugin] Processed \(parsedMessages.count) messages across \(threads.count) threads")
        }
    }

    /// Adds a message the phone reported, or replaces the copy already there.
    /// Messages are matched by the phone's own ID, so two real texts with the
    /// same words a second apart both stay. One Tether added while sending
    /// is replaced when the phone reports it.
    static func merging(_ message: SMSMessage, into messages: [SMSMessage]) -> [SMSMessage] {
        merging([message], into: messages)
    }

    /// Merges a batch into a thread, oldest first. Messages are found by key
    /// through an index built once, and the thread is sorted once at the end,
    /// so a large page costs about as much as its length, not its square.
    static func merging(_ incoming: [SMSMessage], into messages: [SMSMessage]) -> [SMSMessage] {
        var messages = messages
        var indexByKey: [SMSMessage.PhoneKey: Int] = [:]
        for (index, message) in messages.enumerated() {
            if let key = message.phoneKey { indexByKey[key] = index }
        }
        for message in incoming {
            if let key = message.phoneKey {
                if let index = indexByKey[key] {
                    messages[index] = message
                } else if message.isOutgoing, let index = messages.firstIndex(where: {
                    $0.phoneId == nil && $0.isOutgoing && $0.body == message.body
                        && abs($0.date.timeIntervalSince(message.date)) < 120
                }) {
                    // The copy added while sending, now reported by the phone.
                    messages[index] = message
                    indexByKey[key] = index
                } else {
                    indexByKey[key] = messages.count
                    messages.append(message)
                }
            } else {
                // A phone that doesn't send IDs: same words, same kind, within 2 s.
                let isCopy = messages.contains {
                    $0.body == message.body && $0.type == message.type && abs($0.date.timeIntervalSince(message.date)) < 2
                }
                if !isCopy { messages.append(message) }
            }
        }
        messages.sort { $0.date < $1.date }
        return messages
    }
}
