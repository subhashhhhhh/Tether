//
//  SSHSocket.swift
//  Tether
//
//  A TCP connection with async send and exact-length receive, on Network.framework.
//

import Foundation
import Network

nonisolated enum SSHSocketError: LocalizedError {
    case connectFailed(String)
    case closed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .connectFailed(let reason): "Couldn't connect: \(reason)"
        case .closed: "The connection closed."
        case .timedOut: "The connection timed out."
        }
    }
}

nonisolated final class SSHSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.subhashh.tether.ssh.socket")
    /// Bytes received but not yet consumed. Only touched on `queue`.
    private var buffer = Data()
    /// Whether connect() has answered. Only touched on `queue`.
    private var connectAnswered = false

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 15
        // A phone that vanishes without closing the connection (out of range,
        // asleep) leaves a request waiting forever: keepalive only probes idle
        // connections. Give up on unanswered data after 8 s instead, before
        // macOS decides the drive isn't responding and offers "Disconnect All".
        tcp.connectionDropTime = 8
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 22,
            using: NWParameters(tls: nil, tcp: tcp)
        )
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [self] state in
                guard !connectAnswered else { return }
                switch state {
                case .ready:
                    connectAnswered = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    connectAnswered = true
                    continuation.resume(throwing: SSHSocketError.connectFailed(error.localizedDescription))
                case .cancelled:
                    connectAnswered = true
                    continuation.resume(throwing: SSHSocketError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SSHSocketError.connectFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Exactly `count` bytes.
    func receive(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async { self.fill(count, continuation) }
        }
    }

    /// One line ending in "\n", without the line ending. Used only for the
    /// version exchange, which comes before any binary packet.
    func receiveLine(maxLength: Int = 8192) async throws -> String {
        var line = Data()
        while true {
            let byte = try await receive(exactly: 1)
            if byte[0] == UInt8(ascii: "\n") { break }
            line.append(byte)
            if line.count > maxLength { throw SSHSocketError.closed }
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
    }

    private func fill(_ count: Int, _ continuation: CheckedContinuation<Data, Error>) {
        if buffer.count >= count {
            let chunk = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            continuation.resume(returning: chunk)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            if let data, !data.isEmpty { self.buffer.append(data) }
            if self.buffer.count >= count {
                self.fill(count, continuation)
            } else if let error {
                continuation.resume(throwing: SSHSocketError.connectFailed(error.localizedDescription))
            } else if isComplete {
                continuation.resume(throwing: SSHSocketError.closed)
            } else {
                self.fill(count, continuation)
            }
        }
    }

    func close() {
        connection.cancel()
    }
}
