//
//  RPCServer.swift
//  Tether
//
//  ONC RPC over TCP (RFC 5531) on the loopback interface: XDR encoding,
//  record marking, and dispatch to a handler. Requests on a connection are
//  handled concurrently and answered by transaction ID, as NFS clients expect.
//

import Foundation
import Network

// MARK: - XDR (RFC 4506)

nonisolated struct XDRWriter {
    private(set) var data = Data()

    init() {}

    mutating func uint32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func uint64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bool(_ value: Bool) { uint32(value ? 1 : 0) }

    /// Variable-length opaque data or string, padded to 4 bytes.
    mutating func opaque(_ value: Data) {
        uint32(UInt32(value.count))
        fixed(value)
    }

    mutating func string(_ value: String) { opaque(Data(value.utf8)) }

    /// Fixed-length opaque data, padded to 4 bytes.
    mutating func fixed(_ value: Data) {
        data.append(value)
        let padding = (4 - value.count % 4) % 4
        if padding > 0 { data.append(contentsOf: [UInt8](repeating: 0, count: padding)) }
    }

    mutating func append(_ other: XDRWriter) { data.append(other.data) }
}

nonisolated enum XDRError: Error { case truncated }

nonisolated struct XDRReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw XDRError.truncated }
        defer { offset += count }
        return data[offset..<offset + count]
    }

    mutating func uint32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func uint64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func bool() throws -> Bool { try uint32() != 0 }

    mutating func opaque(maxLength: Int = 64 * 1024 * 1024) throws -> Data {
        let count = Int(try uint32())
        guard count <= maxLength else { throw XDRError.truncated }
        return try fixed(count)
    }

    mutating func fixed(_ count: Int) throws -> Data {
        let value = Data(try take(count))
        _ = try take((4 - count % 4) % 4)
        return value
    }

    mutating func string() throws -> String { String(decoding: try opaque(maxLength: 4096), as: UTF8.self) }

    /// Everything not read yet.
    var rest: Data { Data(data[offset...]) }
}

// MARK: - RPC

nonisolated struct RPCCall: Sendable {
    let xid: UInt32
    let program: UInt32
    let version: UInt32
    let procedure: UInt32
    let arguments: Data
}

/// What a handler returns for a call.
nonisolated enum RPCResult: Sendable {
    case success(Data)
    case programUnavailable
    case procedureUnavailable
    case garbageArguments
}

/// Serves RPC programs on 127.0.0.1 at a system-chosen port.
nonisolated final class RPCServer: @unchecked Sendable {
    typealias Handler = @Sendable (RPCCall) async -> RPCResult

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.subhashh.tether.nfs.rpc")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take(), let port = listener.port?.rawValue { continuation.resume(returning: port) }
                case .failed(let error):
                    if once.take() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        // Only this Mac may connect: the listener is bound to loopback, but check anyway.
        if case .hostPort(let host, _) = connection.endpoint, "\(host)" != "127.0.0.1" {
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .cancelled = state { connections.removeValue(forKey: ObjectIdentifier(connection)) }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        readRecord(on: connection, accumulated: Data())
    }

    /// Reads one RPC record (possibly several fragments) and handles it.
    private func readRecord(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let self, let header, header.count == 4, error == nil else { return connection.cancel() }
            let word = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let isLast = word & 0x8000_0000 != 0
            let length = Int(word & 0x7fff_ffff)
            guard length <= 8 * 1024 * 1024 else { return connection.cancel() }

            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, body.count == length, error == nil else { return connection.cancel() }
                let record = accumulated + body
                if isLast {
                    self.dispatch(record, on: connection)
                    self.readRecord(on: connection, accumulated: Data())
                } else {
                    self.readRecord(on: connection, accumulated: record)
                }
            }
            _ = isComplete
        }
    }

    private func dispatch(_ record: Data, on connection: NWConnection) {
        var reader = XDRReader(record)
        guard let xid = try? reader.uint32(),
              (try? reader.uint32()) == 0, // CALL
              (try? reader.uint32()) == 2, // RPC version 2
              let program = try? reader.uint32(),
              let version = try? reader.uint32(),
              let procedure = try? reader.uint32(),
              (try? reader.uint32()) != nil, (try? reader.opaque(maxLength: 400)) != nil, // credentials
              (try? reader.uint32()) != nil, (try? reader.opaque(maxLength: 400)) != nil  // verifier
        else { return }

        let call = RPCCall(xid: xid, program: program, version: version, procedure: procedure,
                           arguments: reader.rest)
        let handler = handler
        Task {
            let result = await handler(call)
            var reply = XDRWriter()
            reply.uint32(xid)
            reply.uint32(1) // REPLY
            reply.uint32(0) // MSG_ACCEPTED
            reply.uint32(0) // verifier: AUTH_NONE
            reply.uint32(0)
            switch result {
            case .success(let body):
                reply.uint32(0)
                var framed = reply.data
                framed.append(body)
                self.send(framed, on: connection)
                return
            case .programUnavailable: reply.uint32(1)
            case .procedureUnavailable: reply.uint32(3)
            case .garbageArguments: reply.uint32(4)
            }
            self.send(reply.data, on: connection)
        }
    }

    private func send(_ reply: Data, on connection: NWConnection) {
        var framed = Data()
        withUnsafeBytes(of: (UInt32(reply.count) | 0x8000_0000).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(reply)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }
}

nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}
