//
//  SMSConversation.swift
//  Tether
//
//  Data model representing an SMS conversation thread.
//

import Foundation

public struct SMSConversation: Identifiable, Sendable, Equatable {
    public var id: Int64 { threadId }
    public let threadId: Int64
    public var addresses: [String]
    public var messages: [SMSMessage]

    public init(threadId: Int64, addresses: [String] = [], messages: [SMSMessage] = []) {
        self.threadId = threadId
        self.addresses = addresses
        self.messages = messages
    }

    public var lastMessage: SMSMessage? {
        messages.last
    }

    public var title: String {
        if !addresses.isEmpty {
            return addresses.joined(separator: ", ")
        }
        return "Conversation \(threadId)"
    }

    public var snippet: String {
        lastMessage?.body ?? ""
    }

    public var unreadCount: Int {
        messages.filter { !$0.read && !$0.isOutgoing }.count
    }

    public var lastDate: Date {
        lastMessage?.date ?? Date.distantPast
    }
}
