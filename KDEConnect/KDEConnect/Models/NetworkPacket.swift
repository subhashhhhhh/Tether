//
//  NetworkPacket.swift
//  KDEConnect
//

import Foundation

public struct AnyCodable: Codable, Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l as Bool, r as Bool): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Int64, r as Int64): return l == r
        case let (l as Double, r as Double): return l == r
        case let (l as String, r as String): return l == r
        case let (l as [String: AnyCodable], r as [String: AnyCodable]): return l == r
        case let (l as [AnyCodable], r as [AnyCodable]): return l == r
        default: return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let int64 = try? container.decode(Int64.self) {
            value = int64
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = ()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int64 as Int64:
            try container.encode(int64)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            let codableArray = array.map { AnyCodable($0) }
            try container.encode(codableArray)
        case let dict as [String: Any]:
            let codableDict = dict.mapValues { AnyCodable($0) }
            try container.encode(codableDict)
        default:
            try container.encodeNil()
        }
    }
}

public struct NetworkPacket: Codable, Sendable {
    public static let protocolVersion: Int = 8

    public var id: Int64
    public var type: String
    public var body: [String: AnyCodable]
    public var payloadSize: Int64?
    public var payloadTransferInfo: [String: AnyCodable]?

    public init(type: String, body: [String: Any] = [:], payloadSize: Int64? = nil, payloadTransferInfo: [String: Any]? = nil) {
        self.id = Int64(Date().timeIntervalSince1970 * 1000)
        self.type = type
        self.body = body.mapValues { AnyCodable($0) }
        self.payloadSize = payloadSize
        self.payloadTransferInfo = payloadTransferInfo?.mapValues { AnyCodable($0) }
    }

    // Body getters
    public func string(for key: String) -> String? {
        body[key]?.value as? String
    }

    public func bool(for key: String, default defaultValue: Bool = false) -> Bool {
        (body[key]?.value as? Bool) ?? defaultValue
    }

    public func int(for key: String, default defaultValue: Int = 0) -> Int {
        if let intVal = body[key]?.value as? Int {
            return intVal
        }
        if let int64Val = body[key]?.value as? Int64 {
            return Int(int64Val)
        }
        return defaultValue
    }

    public func int64(for key: String, default defaultValue: Int64 = 0) -> Int64 {
        if let int64Val = body[key]?.value as? Int64 {
            return int64Val
        }
        if let intVal = body[key]?.value as? Int {
            return Int64(intVal)
        }
        return defaultValue
    }

    public func stringArray(for key: String) -> [String] {
        if let arr = body[key]?.value as? [String] {
            return arr
        }
        if let arr = body[key]?.value as? [Any] {
            return arr.compactMap { $0 as? String }
        }
        return []
    }

    // Packet serialization
    public func serialize() throws -> Data {
        let encoder = JSONEncoder()
        var data = try encoder.encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public static func unserialize(from data: Data) throws -> NetworkPacket {
        let decoder = JSONDecoder()
        return try decoder.decode(NetworkPacket.self, from: data)
    }
}
