//
//  PayloadTransfer.swift
//  Tether
//
//  Binary payload transfer for the KDE Connect protocol.
//
//  Large binary data (files, album art, SMS attachments) does NOT travel over
//  the main packet socket. Instead the sender announces `payloadSize` and
//  `payloadTransferInfo: {"port": N}` in a normal JSON packet, then listens on
//  a separate TCP port and acts as the TLS server. The receiver sees the
//  announcement, connects to that port as a TLS client, and reads exactly
//  `payloadSize` bytes. Both sides present their device certificate.
//

import Foundation
import Network
import Security

// MARK: - Port range and timeouts

nonisolated enum PayloadPort {
    /// Upstream `compositeuploadjob.h` uses 1739...1764 for payload servers.
    static let min: UInt16 = 1739
    static let max: UInt16 = 1764

    /// Upstream waits 30s for the receiver to connect before giving up.
    static let acceptTimeout: TimeInterval = 30

    /// Budget for the TLS handshake, which takes milliseconds; this only
    /// bounds a peer that stops responding.
    static let handshakeTimeout: TimeInterval = 20

    /// Maximum time with no forward progress during the byte stream itself.
    static let ioStallTimeout: TimeInterval = 60

    /// Chunk size used when streaming to keep memory flat for large files.
    static let chunkSize = 64 * 1024
}

// MARK: - Errors

enum PayloadError: Error, LocalizedError {
    case noPortAvailable
    case connectionTimeout
    case tlsHandshakeFailed(OSStatus)
    case socketFailure(Int32)
    case peerClosedEarly(expected: Int64, received: Int64)
    case fileUnreadable(URL)
    case fileUnwritable(URL)
    case certificateMismatch
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noPortAvailable:
            return "No free port in range \(PayloadPort.min)-\(PayloadPort.max) for payload transfer."
        case .connectionTimeout:
            return "Timed out waiting for the peer to connect for the payload transfer."
        case .tlsHandshakeFailed(let status):
            return "TLS handshake for payload transfer failed (status \(status))."
        case .socketFailure(let code):
            return "Socket error during payload transfer (errno \(code))."
        case .peerClosedEarly(let expected, let received):
            return "Peer closed the payload stream early: expected \(expected) bytes, received \(received)."
        case .fileUnreadable(let url):
            return "Could not read file for transfer: \(url.lastPathComponent)"
        case .fileUnwritable(let url):
            return "Could not write received data to \(url.lastPathComponent)."
        case .certificateMismatch:
            return "The payload peer presented a different certificate than the paired device."
        case .cancelled:
            return "Payload transfer cancelled."
        }
    }
}

// MARK: - TLS
//
// Network.framework's TLS. SecureTransport, used before, is deprecated and
// leaked memory on every handshake; the main connection still needs it,
// since it turns TLS on partway through, but a payload socket is TLS from
// the first byte.

nonisolated enum PayloadTLS {
    /// Set when the peer's certificate isn't the paired device's, so the
    /// failed handshake is reported as that rather than as a TLS error.
    final class PeerCheck: @unchecked Sendable {
        private let lock = NSLock()
        private var mismatched = false
        var isMismatch: Bool { lock.withLock { mismatched } }
        func recordMismatch() { lock.withLock { mismatched = true } }
    }

    /// TLS with this Mac's certificate, accepting only a peer holding the
    /// pinned one. Both sides present a certificate, as KDE Connect requires.
    static func parameters(isServer: Bool, expectedPeerFingerprint: String?, check: PeerCheck,
                           label: String, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let identity = sec_identity_create(DeviceIdentity.shared.secIdentity) {
            sec_protocol_options_set_local_identity(sec, identity)
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        if isServer { sec_protocol_options_set_peer_authentication_required(sec, true) }
        // The peer's certificate is self-signed and pinned by fingerprint at
        // pairing. Without this, anyone who can reach the port could feed or
        // receive the data.
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            let leaf = (SecTrustCopyCertificateChain(trustRef) as? [SecCertificate])?.first
            let actual = leaf.map(SocketTLS.fingerprint(of:))
            guard expectedPeerFingerprint == nil || SocketTLS.fingerprintsMatch(actual, expectedPeerFingerprint) else {
                TetherLog("[PayloadTLS] \(label) peer certificate \(actual ?? "none") does not match paired device")
                check.recordMismatch()
                complete(false)
                return
            }
            complete(true)
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        if !isServer { tcp.connectionTimeout = Int(PayloadPort.acceptTimeout) }
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func error(_ error: NWError?, check: PeerCheck) -> PayloadError {
        if check.isMismatch { return .certificateMismatch }
        switch error {
        case .posix(let code)?:
            return code == .ETIMEDOUT ? .connectionTimeout : .socketFailure(code.rawValue)
        case .tls(let status)?:
            return .tlsHandshakeFailed(status)
        default:
            return .connectionTimeout
        }
    }

    /// The first of several callbacks' answers, waited for.
    final class FirstAnswer<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private let answered = DispatchSemaphore(value: 0)
        private var value: Value?

        func answer(_ value: Value) {
            let isFirst = lock.withLock { () -> Bool in
                guard self.value == nil else { return false }
                self.value = value
                return true
            }
            if isFirst { answered.signal() }
        }

        /// Nil if nothing answered in time.
        func wait(_ timeout: TimeInterval) -> Value? {
            guard answered.wait(timeout: .now() + timeout) == .success else { return nil }
            return lock.withLock { value }
        }
    }

    /// Waits for the connection to be ready: connected, handshake done and
    /// the peer checked. Nil when it is, else why not.
    static func waitUntilReady(_ connection: NWConnection, timeout: TimeInterval, check: PeerCheck) -> PayloadError? {
        let outcome = FirstAnswer<PayloadError?>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: outcome.answer(nil)
            // A refused connection waits to retry; a transfer can't.
            case .failed(let error), .waiting(let error): outcome.answer(Self.error(error, check: check))
            case .cancelled: outcome.answer(.cancelled)
            default: break
            }
        }
        return outcome.wait(timeout) ?? .connectionTimeout
    }

    /// Sends and waits until the bytes are handed to the network.
    static func waitForPeerToClose(_ connection: NWConnection, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let closed = FirstAnswer<Bool>()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, complete, error in
                closed.answer(complete || error != nil)
            }
            guard closed.wait(deadline.timeIntervalSinceNow) == false else { return }
        }
    }

    enum SendResult { case sent, failed(NWError), timedOut }

    static func send(_ data: Data?, on connection: NWConnection, isLast: Bool = false) -> SendResult {
        let outcome = FirstAnswer<SendResult>()
        connection.send(content: data, contentContext: isLast ? .finalMessage : .defaultMessage,
                        isComplete: isLast, completion: .contentProcessed { error in
            outcome.answer(error.map(SendResult.failed) ?? .sent)
        })
        return outcome.wait(PayloadPort.ioStallTimeout) ?? .timedOut
    }
}

// MARK: - Upload (we send a payload: we are the TLS server)

/// Announces a payload and streams the bytes once the peer connects.
///
/// Lifecycle: `start` binds a port and hands it back via `onReady` so the caller
/// can send the announcing packet, then the transfer proceeds asynchronously.
nonisolated final class PayloadUploader: @unchecked Sendable {

    /// Details the caller needs in order to announce the transfer.
    struct Offer {
        let port: UInt16
        let size: Int64
    }

    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var isFinished = false
    private var onComplete: ((Result<Void, Error>) -> Void)?

    /// Keeps the uploader alive for the duration of a transfer: a caller may
    /// drop its reference right after `start`.
    private var selfReference: PayloadUploader?

    private let queue = DispatchQueue(label: "com.subhashh.tether.payload.upload", qos: .userInitiated)
    private let check = PayloadTLS.PeerCheck()

    init() {}

    /// Opens a listening port and begins waiting for the receiver.
    ///
    /// - Parameter onReady: Invoked once the port is bound. The caller must send the
    ///   payload-announcing packet after this returns, otherwise the peer has nothing
    ///   to connect to and the transfer will time out.
    func start(
        fileURL: URL,
        expectedPeerFingerprint: String? = nil,
        onReady: @escaping (Offer) -> Void,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            onComplete(.failure(PayloadError.fileUnreadable(fileURL)))
            return
        }
        let parameters = PayloadTLS.parameters(isServer: true, expectedPeerFingerprint: expectedPeerFingerprint,
                                               check: check, label: "server", queue: queue)
        guard let (listener, port) = Self.listen(using: parameters, queue: queue) else {
            onComplete(.failure(PayloadError.noPortAvailable))
            return
        }

        stateLock.withLock {
            self.listener = listener
            self.onComplete = onComplete
            self.selfReference = self
        }
        // One receiver per offer; anyone after it is turned away.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let accepted = self.stateLock.withLock { () -> Bool in
                guard self.connection == nil, !self.isFinished else { return false }
                self.connection = connection
                return true
            }
            guard accepted else { connection.cancel(); return }
            listener.cancel()
            DispatchQueue.global(qos: .userInitiated).async {
                self.stream(fileURL: fileURL, size: size, over: connection, onProgress: onProgress)
            }
        }
        queue.asyncAfter(deadline: .now() + PayloadPort.acceptTimeout) { [weak self] in
            guard let self, self.stateLock.withLock({ self.connection == nil }) else { return }
            TetherLog("[PayloadUploader] Timed out waiting for receiver to connect")
            self.finish(.failure(PayloadError.connectionTimeout))
        }
        TetherLog("[PayloadUploader] Listening on port \(port) for \(fileURL.lastPathComponent) (\(size) bytes)")
        onReady(Offer(port: port, size: size))
    }

    /// The first free port in the range upstream reserves, on IPv4 and IPv6.
    private static func listen(using parameters: NWParameters, queue: DispatchQueue) -> (NWListener, UInt16)? {
        for candidate in PayloadPort.min...PayloadPort.max {
            guard let port = NWEndpoint.Port(rawValue: candidate),
                  let listener = try? NWListener(using: parameters, on: port) else { continue }
            let isReady = PayloadTLS.FirstAnswer<Bool>()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: isReady.answer(true)
                case .failed, .waiting, .cancelled: isReady.answer(false)
                default: break
                }
            }
            // Connections that arrive before the handler is set wait for it.
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
            if isReady.wait(2) == true {
                return (listener, candidate)
            }
            listener.cancel()
        }
        return nil
    }

    private func stream(fileURL: URL, size: Int64, over connection: NWConnection, onProgress: @escaping (Double) -> Void) {
        connection.start(queue: queue)
        if let error = PayloadTLS.waitUntilReady(connection, timeout: PayloadPort.handshakeTimeout, check: check) {
            TetherLog("[PayloadUploader] Receiver didn't connect: \(error.localizedDescription)")
            finish(.failure(error))
            return
        }
        guard let file = try? FileHandle(forReadingFrom: fileURL) else {
            finish(.failure(PayloadError.fileUnreadable(fileURL)))
            return
        }
        defer { try? file.close() }

        var sent: Int64 = 0
        var lastReported = 0.0
        while sent < size {
            if stateLock.withLock({ isFinished }) { return }
            let want = Int(min(Int64(PayloadPort.chunkSize), size - sent))
            guard let chunk = try? file.read(upToCount: want), !chunk.isEmpty else { break }
            switch PayloadTLS.send(chunk, on: connection) {
            case .timedOut:
                finish(.failure(PayloadError.connectionTimeout))
                return
            case .failed(let error):
                // After a cancel this finds the transfer already finished.
                finish(.failure(PayloadTLS.error(error, check: check)))
                return
            case .sent:
                break
            }
            sent += Int64(chunk.count)
            // Whole percents, as downloads report.
            let fraction = Double(sent) / Double(size)
            if fraction - lastReported >= 0.01 || sent == size {
                lastReported = fraction
                onProgress(fraction)
            }
        }
        guard sent == size else {
            finish(.failure(PayloadError.peerClosedEarly(expected: size, received: sent)))
            return
        }
        // Ends the TLS session, then waits briefly for the phone to close its
        // side: closing first can reset the connection and lose bytes it
        // hasn't read yet.
        _ = PayloadTLS.send(nil, on: connection, isLast: true)
        PayloadTLS.waitForPeerToClose(connection)
        TetherLog("[PayloadUploader] Sent \(sent) bytes for \(fileURL.lastPathComponent)")
        finish(.success(()))
    }

    func cancel() {
        finish(.failure(PayloadError.cancelled))
    }

    /// Reports once, and lets go of the listener and connection.
    private func finish(_ result: Result<Void, Error>) {
        let teardown = stateLock.withLock { () -> (NWListener?, NWConnection?, ((Result<Void, Error>) -> Void)?, PayloadUploader?)? in
            guard !isFinished else { return nil }
            isFinished = true
            defer { listener = nil; connection = nil; onComplete = nil; selfReference = nil }
            return (listener, connection, onComplete, selfReference)
        }
        guard let (listener, connection, onComplete, retained) = teardown else { return }
        listener?.cancel()
        if case .success = result { connection?.cancel() } else { connection?.forceCancel() }
        onComplete?(result)
        _ = retained
    }
}

// MARK: - Download (we receive a payload: we are the TLS client)

nonisolated enum PayloadDownloader {

    /// Where in-flight downloads are written before a plugin claims them.
    static var incomingDirectory: URL {
        let caches = URL.cachesDirectory
        return caches.appendingPathComponent("TetherIncoming", isDirectory: true)
    }

    /// Stops a download in progress.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var connection: NWConnection?

        var isCancelled: Bool { lock.withLock { cancelled } }

        func attach(_ connection: NWConnection) -> Bool {
            lock.withLock {
                self.connection = connection
                return !cancelled
            }
        }

        func cancel() {
            let connection = lock.withLock { () -> NWConnection? in
                cancelled = true
                return self.connection
            }
            // Ends a receive that is waiting.
            connection?.forceCancel()
        }
    }

    /// Connects to the peer's payload server and streams `size` bytes to a
    /// temporary file, so memory stays flat no matter how large the file is.
    /// A size of -1 means the phone didn't know it (a file from some apps):
    /// then everything until the phone closes the connection is the file.
    ///
    /// - Parameters:
    ///   - host: Address of the peer that announced the transfer.
    ///   - port: Port taken from `payloadTransferInfo["port"]`.
    ///   - size: Expected byte count from the packet's `payloadSize`.
    ///   - expectedPeerFingerprint: Pinned certificate of the paired device; the
    ///     transfer is refused if the payload server presents anything else.
    ///   - completion: Receives the temporary file. The caller owns it and must
    ///     move or delete it.
    @discardableResult
    static func download(
        host: String,
        port: UInt16,
        size: Int64,
        expectedPeerFingerprint: String?,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) -> Handle {
        let handle = Handle()
        DispatchQueue.global(qos: .userInitiated).async {
            let destination = incomingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
            let result: Result<URL, Error>
            if size == 0 {
                // Nothing to fetch: an empty file is the whole file.
                try? FileManager.default.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
                result = FileManager.default.createFile(atPath: destination.path, contents: Data())
                    ? .success(destination) : .failure(PayloadError.fileUnwritable(destination))
            } else {
                result = performDownload(
                    host: host,
                    port: port,
                    size: size,
                    expectedPeerFingerprint: expectedPeerFingerprint,
                    destination: destination,
                    handle: handle,
                    onProgress: onProgress
                )
            }
            if case .failure = result {
                try? FileManager.default.removeItem(at: destination)
            }
            completion(result)
        }
        return handle
    }

    private static func performDownload(
        host: String,
        port: UInt16,
        size: Int64,
        expectedPeerFingerprint: String?,
        destination: URL,
        handle: Handle,
        onProgress: @escaping (Double) -> Void
    ) -> Result<URL, Error> {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failure(PayloadError.socketFailure(EINVAL)) }
        let queue = DispatchQueue(label: "com.subhashh.tether.payload.download", qos: .userInitiated)
        let check = PayloadTLS.PeerCheck()
        let parameters = PayloadTLS.parameters(isServer: false, expectedPeerFingerprint: expectedPeerFingerprint,
                                               check: check, label: "client", queue: queue)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        guard handle.attach(connection) else { return .failure(PayloadError.cancelled) }
        defer { connection.forceCancel() }

        connection.start(queue: queue)
        if let error = PayloadTLS.waitUntilReady(connection, timeout: PayloadPort.acceptTimeout + PayloadPort.handshakeTimeout, check: check) {
            if handle.isCancelled { return .failure(PayloadError.cancelled) }
            TetherLog("[PayloadDownloader] Couldn't connect to \(host):\(port): \(error.localizedDescription)")
            return .failure(error)
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else {
            return .failure(PayloadError.fileUnwritable(destination))
        }
        defer { try? output.close() }

        let isSizeKnown = size > 0
        var received: Int64 = 0
        var lastReported = 0.0
        while !isSizeKnown || received < size {
            if handle.isCancelled { return .failure(PayloadError.cancelled) }
            let chunk = PayloadTLS.FirstAnswer<(data: Data?, isComplete: Bool, error: NWError?)>()
            let wanted = isSizeKnown ? Int(min(Int64(PayloadPort.chunkSize), size - received)) : PayloadPort.chunkSize
            connection.receive(minimumIncompleteLength: 1, maximumLength: wanted) { content, _, complete, error in
                chunk.answer((content, complete, error))
            }
            guard let (data, isComplete, receiveError) = chunk.wait(PayloadPort.ioStallTimeout) else {
                TetherLog("[PayloadDownloader] Stalled after \(received)/\(size) bytes")
                return .failure(PayloadError.connectionTimeout)
            }
            if handle.isCancelled { return .failure(PayloadError.cancelled) }

            if let data, !data.isEmpty {
                do {
                    try output.write(contentsOf: data)
                } catch {
                    return .failure(PayloadError.fileUnwritable(destination))
                }
                received += Int64(data.count)
                // Whole percents.
                if isSizeKnown {
                    let fraction = Double(received) / Double(size)
                    if fraction - lastReported >= 0.01 || received == size {
                        lastReported = fraction
                        onProgress(fraction)
                    }
                }
            }
            guard isComplete || receiveError != nil else { continue }
            if !isSizeKnown {
                // The end of a file of unknown size, however the phone closed.
                TetherLog("[PayloadDownloader] Received \(received) bytes (size not announced) from \(host):\(port)")
                return .success(destination)
            }
            break
        }

        guard received == size else {
            TetherLog("[PayloadDownloader] Incomplete payload: \(received)/\(size) bytes")
            return .failure(PayloadError.peerClosedEarly(expected: size, received: received))
        }

        TetherLog("[PayloadDownloader] Received \(received) bytes from \(host):\(port)")
        return .success(destination)
    }

}
