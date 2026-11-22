//
//  SSHWire.swift
//  Tether
//
//  SSH's binary encoding (RFC 4251 §5): bytes, big-endian integers, length-
//  prefixed strings, name-lists and mpints.
//

import Foundation

nonisolated enum SSHWireError: Error {
    case truncated
    case malformed(String)
}

nonisolated struct SSHWriter {
    private(set) var data = Data()

    init() {}

    mutating func byte(_ value: UInt8) { data.append(value) }

    mutating func bool(_ value: Bool) { data.append(value ? 1 : 0) }

    mutating func uint32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func uint64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }

    mutating func string(_ value: String) { string(Data(value.utf8)) }

    mutating func nameList(_ names: [String]) { string(names.joined(separator: ",")) }

    /// An unsigned big-endian integer as an mpint: no leading zero bytes, plus
    /// one zero byte when the top bit is set so it isn't read as negative.
    mutating func mpint(unsigned bytes: Data) {
        var trimmed = bytes.drop { $0 == 0 }
        if let first = trimmed.first, first & 0x80 != 0 {
            trimmed.insert(0, at: trimmed.startIndex)
        }
        string(Data(trimmed))
    }

    mutating func raw(_ value: Data) { data.append(value) }
}

nonisolated struct SSHReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw SSHWireError.truncated }
        let slice = data[offset..<offset + count]
        offset += count
        return Data(slice)
    }

    mutating func byte() throws -> UInt8 { try bytes(1)[0] }

    mutating func bool() throws -> Bool { try byte() != 0 }

    mutating func uint32() throws -> UInt32 {
        try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func uint64() throws -> UInt64 {
        try bytes(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func string() throws -> Data { try bytes(Int(try uint32())) }

    mutating func utf8() throws -> String {
        guard let text = String(data: try string(), encoding: .utf8) else {
            throw SSHWireError.malformed("string is not UTF-8")
        }
        return text
    }

    mutating func nameList() throws -> [String] {
        let text = try utf8()
        return text.isEmpty ? [] : text.split(separator: ",").map(String.init)
    }

    /// An mpint's magnitude as unsigned big-endian bytes.
    mutating func mpint() throws -> Data {
        Data(try string().drop { $0 == 0 })
    }
}

nonisolated extension UInt32 {
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
