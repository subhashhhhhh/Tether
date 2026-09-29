//
//  SMSPlugin.swift
//  Tether
//
//  Plugin for viewing and replying to SMS conversations from macOS.
//

import Foundation
import Combine

public final class SMSPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {
    public static let messagesType = "kdeconnect.sms.messages"
    public static let attachmentFileType = "kdeconnect.sms.attachment_file"
    public static let requestType = "kdeconnect.sms.request"
    public static let requestConversationsType = "kdeconnect.sms.request_conversations"
    public static let requestConversationType = "kdeconnect.sms.request_conversation"
    public static let requestAttachmentType = "kdeconnect.sms.request_attachment"

    public var supportedPacketTypes: [String] {
        [Self.messagesType, Self.attachmentFileType]
    }

    @Published public private(set) var conversations: [Int64: SMSConversation] = [:]
    @Published public private(set) var activeThreadId: Int64?

    private let lock = NSLock()

    public init() {}

    public func onConnected(connection: DeviceConnection) {
        requestAllConversations(connection: connection)
    }

    public func onDisconnected(connection: DeviceConnection) {}

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        if packet.type == Self.messagesType {
            handleBatchMessages(packet: packet)
        }
    }

    public func handlePayload(connection: DeviceConnection, packet: NetworkPacket, data: Data) {
        guard packet.type == Self.attachmentFileType else { return }
        let filename = packet.string(for: "filename") ?? "attachment"
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let attachmentDir = cachesDir.appendingPathComponent("TetherAttachments", isDirectory: true)

        try? FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
        let fileURL = attachmentDir.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL, options: .atomic)
            TetherLog("[SMSPlugin] Saved SMS attachment to \(fileURL.path)")

            let targetThreadId = (packet.int64(for: "thread_id")) != 0 ? packet.int64(for: "thread_id") : nil
            if let threadId = targetThreadId {
                DispatchQueue.main.async {
                    if var conversation = self.conversations[threadId] {
                        for msgIndex in conversation.messages.indices {
                            for attIndex in conversation.messages[msgIndex].attachments.indices {
                                if conversation.messages[msgIndex].attachments[attIndex].uniqueIdentifier == filename {
                                    conversation.messages[msgIndex].attachments[attIndex].localURL = fileURL
                                }
                            }
                        }
                        self.conversations[threadId] = conversation
                    }
                }
            }
        } catch {
            TetherLog("[SMSPlugin] Failed to write attachment: \(error)")
        }
    }

    // MARK: - Actions

    public func requestAllConversations(connection: DeviceConnection) {
        let packet = NetworkPacket(type: Self.requestConversationsType)
        connection.send(packet: packet)
        TetherLog("[SMSPlugin] Requested all SMS conversations")
    }

    public func requestConversation(threadId: Int64, rangeStartTimestamp: Int64 = 0, numberToRequest: Int = 50, connection: DeviceConnection) {
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

    public func sendSMS(text: String, to addresses: [String], threadId: Int64? = nil, connection: DeviceConnection) {
        guard !text.isEmpty, !addresses.isEmpty else { return }

        let addressList = addresses.map { ["address": AnyCodable($0)] }
        let packet = NetworkPacket(
            type: Self.requestType,
            body: [
                "version": AnyCodable(2),
                "addresses": AnyCodable(addressList),
                "messageBody": AnyCodable(text)
            ]
        )
        connection.send(packet: packet)
        TetherLog("[SMSPlugin] Dispatched SMS to \(addresses.joined(separator: ", "))")

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
                if var conv = self.conversations[targetThreadId] {
                    conv.messages.append(optimisticMessage)
                    self.conversations[targetThreadId] = conv
                }
            }
        }
    }

    public func setActiveThread(_ threadId: Int64?) {
        DispatchQueue.main.async {
            self.activeThreadId = threadId
        }
    }

    // MARK: - Internal Message Parsing

    private func handleBatchMessages(packet: NetworkPacket) {
        let rawMessages = packet.objectArray(for: "messages")
        guard !rawMessages.isEmpty else { return }

        var parsedMessages: [SMSMessage] = []
        for raw in rawMessages {
            if let msg = SMSMessage.from(dictionary: raw) {
                parsedMessages.append(msg)
            }
        }

        guard !parsedMessages.isEmpty else { return }

        DispatchQueue.main.async {
            for message in parsedMessages {
                let threadId = message.threadId
                var conversation = self.conversations[threadId] ?? SMSConversation(threadId: threadId, addresses: message.addresses)

                if conversation.addresses.isEmpty && !message.addresses.isEmpty {
                    conversation.addresses = message.addresses
                }

                // Check for duplicates
                if !conversation.messages.contains(where: {
                    $0.body == message.body &&
                    abs($0.date.timeIntervalSince(message.date)) < 2.0 &&
                    $0.type == message.type
                }) {
                    conversation.messages.append(message)
                }

                // Sort chronologically
                conversation.messages.sort(by: { $0.date < $1.date })
                self.conversations[threadId] = conversation
            }
            TetherLog("[SMSPlugin] Processed \(parsedMessages.count) messages across \(self.conversations.count) threads")
        }
    }
}
