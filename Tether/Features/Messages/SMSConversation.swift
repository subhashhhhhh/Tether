//
//  SMSConversation.swift
//  Tether
//
//  Data model representing an SMS conversation thread.
//

import Foundation

struct SMSConversation: Identifiable, Sendable, Equatable {
    var id: Int64 { threadId }
    let threadId: Int64
    var addresses: [String]
    var messages: [SMSMessage]

    init(threadId: Int64, addresses: [String] = [], messages: [SMSMessage] = []) {
        self.threadId = threadId
        self.addresses = addresses
        self.messages = messages
    }

    var lastMessage: SMSMessage? {
        messages.last
    }

    var title: String {
        if !addresses.isEmpty {
            return addresses.joined(separator: ", ")
        }
        return "Conversation \(threadId)"
    }

    var snippet: String {
        lastMessage?.body ?? ""
    }

    var unreadCount: Int {
        messages.filter { !$0.read && !$0.isOutgoing }.count
    }

    var lastDate: Date {
        lastMessage?.date ?? Date.distantPast
    }
}
