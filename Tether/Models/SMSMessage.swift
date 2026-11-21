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
    /// The SIM it went through (`sub_id`), when the phone knows.
    public let subId: Int64?
    public var attachments: [SMSAttachment]
    /// The phone's own ID for it (`_id`); nil for one Tether added while
    /// sending, before the phone reported it. SMS and MMS number theirs
    /// separately, so it's paired with the date to name one message.
    public var phoneId: Int64? = nil

    /// What names this message on the phone, as KDE Connect desktop keys it.
    public struct PhoneKey: Hashable, Sendable {
        let id: Int64
        let milliseconds: Int64
    }
    public var phoneKey: PhoneKey? { phoneId.map { PhoneKey(id: $0, milliseconds: Int64(date.timeIntervalSince1970 * 1000)) } }

    /// Android's message box: 1 inbox, 2 sent, 4 outbox, 5 failed, 6
    /// queued. Everything but the inbox was written on the phone.
    public var isOutgoing: Bool {
        [2, 4, 5, 6].contains(type)
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
        subId: Int64? = nil,
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
        self.subId = subId
        self.attachments = attachments
    }

    nonisolated public static func from(dictionary dict: [String: Any]) -> SMSMessage? {
        let body = (dict["body"] as? String) ?? ""
        let event = integer(dict["event"]).map(Int.init) ?? 1
        let type = integer(dict["type"]).map(Int.init) ?? 1
        let threadId = integer(dict["thread_id"]) ?? 0

        let readVal: Bool
        if let b = dict["read"] as? Bool {
            readVal = b
        } else if let i = dict["read"] as? Int {
            readVal = (i != 0)
        } else {
            readVal = true
        }

        // Phones that can't tell report 0, which isn't a real SIM.
        let subId = integer(dict["sub_id"])

        let dateMs = integer(dict["date"]) ?? 0
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
                let partId = integer(att["part_id"]) ?? 0
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

        var message = SMSMessage(
            event: event,
            body: body,
            addresses: addressList,
            date: date,
            type: type,
            threadId: threadId,
            read: readVal,
            subId: subId.flatMap { $0 > 0 ? $0 : nil },
            attachments: parsedAttachments
        )
        message.phoneId = integer(dict["_id"])
        return message
    }

    /// A number from the phone's JSON, which may arrive as Int, Int64,
    /// NSNumber or a string.
    nonisolated private static func integer(_ value: Any?) -> Int64? {
        switch value {
        case let int as Int: Int64(int)
        case let int64 as Int64: int64
        case let number as NSNumber: number.int64Value
        case let string as String: Int64(string.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}
