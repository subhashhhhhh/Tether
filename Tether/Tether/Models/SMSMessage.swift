//
//  SMSMessage.swift
//  Tether
//
//  Data model for KDE Connect SMS messages and attachments.
//

import Foundation

public struct SMSAttachment: Identifiable, Sendable, Equatable {
    public let id: String
    public let partId: Int64
    public let mimeType: String
    public let encodedThumbnail: String?
    public let uniqueIdentifier: String
    public var localURL: URL?

    public init(
        partId: Int64,
        mimeType: String,
        encodedThumbnail: String? = nil,
        uniqueIdentifier: String,
        localURL: URL? = nil
    ) {
        self.id = "\(partId)_\(uniqueIdentifier)"
        self.partId = partId
        self.mimeType = mimeType
        self.encodedThumbnail = encodedThumbnail
        self.uniqueIdentifier = uniqueIdentifier
        self.localURL = localURL
    }
}

public struct SMSMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let event: Int
    public let body: String
    public let addresses: [String]
    public let date: Date
    /// 1 = incoming/received, 2 = outgoing/sent, 3 = draft
    public let type: Int
    public let threadId: Int64
    public let read: Bool
    public var attachments: [SMSAttachment]

    public var isOutgoing: Bool {
        type == 2
    }

    public var formattedTime: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .short
        }
        return formatter.string(from: date)
    }

    public init(
        id: UUID = UUID(),
        event: Int = 1,
        body: String,
        addresses: [String],
        date: Date,
        type: Int,
        threadId: Int64,
        read: Bool,
        attachments: [SMSAttachment] = []
    ) {
        self.id = id
        self.event = event
        self.body = body
        self.addresses = addresses
        self.date = date
        self.type = type
        self.threadId = threadId
        self.read = read
        self.attachments = attachments
    }

    public static func from(dictionary dict: [String: Any]) -> SMSMessage? {
        let body = (dict["body"] as? String) ?? ""
        let event = (dict["event"] as? Int) ?? 1
        let type = (dict["type"] as? Int) ?? 1
        let threadId = (dict["thread_id"] as? Int64) ?? Int64((dict["thread_id"] as? Int) ?? 0)

        let readVal: Bool
        if let b = dict["read"] as? Bool {
            readVal = b
        } else if let i = dict["read"] as? Int {
            readVal = (i != 0)
        } else {
            readVal = true
        }

        let dateMs = (dict["date"] as? Int64) ?? Int64((dict["date"] as? Int) ?? 0)
        let date = dateMs > 0 ? Date(timeIntervalSince1970: Double(dateMs) / 1000.0) : Date()

        var addressList: [String] = []
        if let addrArray = dict["addresses"] as? [[String: Any]] {
            for item in addrArray {
                if let addr = item["address"] as? String {
                    addressList.append(addr)
                }
            }
        }

        var parsedAttachments: [SMSAttachment] = []
        if let rawAttachments = dict["attachments"] as? [[String: Any]] {
            for att in rawAttachments {
                let partId = (att["part_id"] as? Int64) ?? Int64((att["part_id"] as? Int) ?? 0)
                let mimeType = (att["mime_type"] as? String) ?? "application/octet-stream"
                let thumbnail = att["encoded_thumbnail"] as? String
                let uniqueId = (att["unique_identifier"] as? String) ?? UUID().uuidString
                parsedAttachments.append(SMSAttachment(
                    partId: partId,
                    mimeType: mimeType,
                    encodedThumbnail: thumbnail,
                    uniqueIdentifier: uniqueId
                ))
            }
        }

        return SMSMessage(
            event: event,
            body: body,
            addresses: addressList,
            date: date,
            type: type,
            threadId: threadId,
            read: readVal,
            attachments: parsedAttachments
        )
    }
}
