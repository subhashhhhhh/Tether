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
import Security
import Darwin

// MARK: - Port range and timeouts

public enum PayloadPort {
    /// Upstream `compositeuploadjob.h` uses 1739...1764 for payload servers.
    public static let min: UInt16 = 1739
    public static let max: UInt16 = 1764

    /// Upstream waits 30s for the receiver to connect before giving up.
    public static let acceptTimeout: TimeInterval = 30

    /// Budget for the TLS handshake. Handshakes take milliseconds now that the
    /// identity is held in memory; this only bounds a peer that stops responding.
    public static let handshakeTimeout: TimeInterval = 20

    /// Maximum time with no forward progress during the byte stream itself.
    public static let ioStallTimeout: TimeInterval = 60

    /// Chunk size used when streaming to keep memory flat for large files.
    static let chunkSize = 64 * 1024
}

// MARK: - Errors

public enum PayloadError: Error, LocalizedError {
    case noPortAvailable
    case connectionTimeout
    case tlsHandshakeFailed(OSStatus)
    case socketFailure(Int32)
    case peerClosedEarly(expected: Int64, received: Int64)
    case fileUnreadable(URL)
    case fileUnwritable(URL)
    case certificateMismatch
    case cancelled

    public var errorDescription: String? {
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

// MARK: - Non-blocking socket IO callbacks

/// Non-blocking read, mirroring the contract used by `DeviceConnection`.
///
/// Payload sockets are put in non-blocking mode so a single `SSLHandshake` or
/// `SSLRead` call can never block past its parent deadline — SecureTransport is
/// expected to be re-driven by a polling loop that owns the timeout instead.
///
/// `errSSLWouldBlock` always means "call me again"; it must never be reported for
/// a transient condition, or the TLS state machine is poisoned.
private func payloadSSLRead(
    connection: SSLConnectionRef,
    data: UnsafeMutableRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = Int32(bitPattern: UInt32(UInt(bitPattern: connection)))
    let requested = dataLength.pointee
    var totalRead = 0
    var ptr = data

    while totalRead < requested {
        let n = Darwin.read(fd, ptr, requested - totalRead)
        if n > 0 {
            totalRead += n
            ptr = ptr.advanced(by: n)
            continue
        }
        if n == 0 {
            dataLength.pointee = totalRead
            return totalRead > 0 ? OSStatus(errSSLWouldBlock) : OSStatus(errSSLClosedGraceful)
        }

        let err = errno
        if err == EINTR { continue }
        if err == EAGAIN || err == EWOULDBLOCK {
            // Partial record already read: hand it back so the caller can re-drive.
            dataLength.pointee = totalRead
            return OSStatus(errSSLWouldBlock)
        }
        if err == ECONNRESET || err == EPIPE || err == ENOTCONN || err == ESHUTDOWN {
            dataLength.pointee = totalRead
            return totalRead > 0 ? OSStatus(errSSLWouldBlock) : OSStatus(errSSLClosedGraceful)
        }

        dataLength.pointee = totalRead
        return OSStatus(errSSLClosedAbort)
    }

    dataLength.pointee = totalRead
    return noErr
}

private func payloadSSLWrite(
    connection: SSLConnectionRef,
    data: UnsafeRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = Int32(bitPattern: UInt32(UInt(bitPattern: connection)))
    let requested = dataLength.pointee
    var totalWritten = 0
    var ptr = data

    while totalWritten < requested {
        let n = Darwin.write(fd, ptr, requested - totalWritten)
        if n > 0 {
            totalWritten += n
            ptr = ptr.advanced(by: n)
            continue
        }
        if n == 0 {
            dataLength.pointee = totalWritten
            return OSStatus(errSSLClosedGraceful)
        }

        let err = errno
        if err == EINTR { continue }
        if err == EAGAIN || err == EWOULDBLOCK {
            dataLength.pointee = totalWritten
            return OSStatus(errSSLWouldBlock)
        }
        if err == EPIPE || err == ECONNRESET || err == ESHUTDOWN {
            dataLength.pointee = totalWritten
            return OSStatus(errSSLClosedGraceful)
        }

        dataLength.pointee = totalWritten
        return OSStatus(errSSLClosedAbort)
    }

    dataLength.pointee = totalWritten
    return noErr
}

// MARK: - Shared TLS helpers

enum PayloadTLS {
    /// Puts a payload socket in non-blocking mode. Timeouts are enforced by the
    /// polling loops in this file, not by the socket.
    static func configureSocket(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Drives the TLS handshake until it completes or the deadline passes.
    ///
    /// The first `SSLHandshake` on a cold process can spend several seconds
    /// resolving the signing identity in the keychain before reporting
    /// `errSSLClientCertRequested`, so the deadline here must be generous.
    static func handshake(_ ctx: SSLContext, fd: Int32, deadline: Date, label: String) -> OSStatus {
        let status = SocketTLS.handshake(ctx, fd: fd, deadline: deadline)
        TetherLog("[PayloadTLS] \(label) handshake finished with status \(status)")
        return status
    }

    /// The payload socket must be held by the same device we are paired with.
    /// Without this, anyone who can reach the port could feed or receive the data.
    static func verifyPeer(_ ctx: SSLContext, expected: String?, label: String) -> Bool {
        guard let expected else { return true }
        let actual = SocketTLS.peerFingerprint(ctx)
        guard SocketTLS.fingerprintsMatch(actual, expected) else {
            TetherLog("[PayloadTLS] \(label) peer certificate \(actual ?? "none") does not match paired device")
            return false
        }
        return true
    }

    static func makeContext(isServer: Bool, fd: Int32) -> SSLContext? {
        guard let ctx = SSLCreateContext(
            kCFAllocatorDefault,
            isServer ? .serverSide : .clientSide,
            .streamType
        ) else { return nil }

        SSLSetIOFuncs(ctx, payloadSSLRead, payloadSSLWrite)
        SSLSetConnection(ctx, SSLConnectionRef(bitPattern: UInt(UInt32(bitPattern: fd))))
        SSLSetCertificate(ctx, [DeviceIdentity.shared.secIdentity] as CFArray)

        if isServer {
            SSLSetClientSideAuthenticate(ctx, .alwaysAuthenticate)
            SSLSetSessionOption(ctx, .breakOnClientAuth, true)
        } else {
            // The peer uses a self-signed certificate that we pin by fingerprint
            // during pairing, so surface the auth event rather than rejecting.
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)
            SSLSetSessionOption(ctx, .breakOnCertRequested, true)
        }
        return ctx
    }
}

// MARK: - Upload (we send a payload: we are the TLS server)

/// Announces a payload and streams the bytes once the peer connects.
///
/// Lifecycle: `start` binds a port and hands it back via `onReady` so the caller
/// can send the announcing packet, then the transfer proceeds asynchronously.
public final class PayloadUploader: @unchecked Sendable {

    /// Details the caller needs in order to announce the transfer.
    public struct Offer {
        public let port: UInt16
        public let size: Int64
    }

    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptedFD: Int32 = -1
    private var sslContext: SSLContext?
    private var isFinished = false

    /// Keeps the uploader alive for the duration of a transfer. The accept and
    /// stream work happens on `queue`, so without this a caller that drops its
    /// reference right after `start` would silently stall the transfer.
    private var selfReference: PayloadUploader?

    private let queue = DispatchQueue(label: "com.subhashh.tether.payload.upload", qos: .userInitiated)

    public init() {}

    /// Opens a listening socket and begins waiting for the receiver.
    ///
    /// - Parameter onReady: Invoked once the port is bound. The caller must send the
    ///   payload-announcing packet after this returns, otherwise the peer has nothing
    ///   to connect to and the transfer will time out.
    public func start(
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

        var fd: Int32 = -1
        var chosenPort: UInt16 = 0

        var candidate = PayloadPort.min
        while candidate <= PayloadPort.max {
            let candidateFD = Self.makeListeningSocket(port: candidate)
            if candidateFD >= 0 {
                fd = candidateFD
                chosenPort = candidate
                break
            }
            candidate += 1
        }

        guard fd >= 0 else {
            onComplete(.failure(PayloadError.noPortAvailable))
            return
        }

        stateLock.withLock {
            self.listenFD = fd
            self.selfReference = self
        }
        TetherLog("[PayloadUploader] Listening on port \(chosenPort) for \(fileURL.lastPathComponent) (\(size) bytes)")

        onReady(Offer(port: chosenPort, size: size))

        queue.async { [weak self] in
            self?.acceptAndStream(
                fileURL: fileURL,
                size: size,
                expectedPeerFingerprint: expectedPeerFingerprint,
                onProgress: onProgress,
                onComplete: onComplete
            )
        }
    }

    private static func makeListeningSocket(port: UInt16) -> Int32 {
        // IPv4 and IPv6, so the phone can fetch over either.
        let fd = SocketAddress.listener(port: port, reusePort: false)
        guard fd >= 0 else { return -1 }

        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    private func acceptAndStream(
        fileURL: URL,
        size: Int64,
        expectedPeerFingerprint: String?,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        let listenSocket = stateLock.withLock { listenFD }
        guard listenSocket >= 0 else {
            onComplete(.failure(PayloadError.cancelled))
            return
        }

        // Wait for the receiver, bounded by the upstream 30s window. Uses poll()
        // rather than a timer because this queue is blocked by the transfer.
        var pollFd = pollfd(fd: listenSocket, events: Int16(POLLIN), revents: 0)
        let pollResult = Darwin.poll(&pollFd, 1, Int32(PayloadPort.acceptTimeout * 1000))
        TetherLog("[PayloadUploader] poll on fd \(listenSocket) returned \(pollResult) (revents \(pollFd.revents))")

        guard pollResult > 0, (pollFd.revents & Int16(POLLIN)) != 0 else {
            if stateLock.withLock({ isFinished }) { return }
            TetherLog("[PayloadUploader] Timed out waiting for receiver to connect")
            finish(
                with: .failure(pollResult == 0 ? PayloadError.connectionTimeout : PayloadError.socketFailure(errno)),
                onComplete: onComplete
            )
            return
        }

        guard let clientFD = SocketAddress.accept(listenSocket)?.fd else {
            finish(with: .failure(PayloadError.socketFailure(errno)), onComplete: onComplete)
            return
        }

        stateLock.withLock { self.acceptedFD = clientFD }
        TetherLog("[PayloadUploader] Accepted payload connection on fd \(clientFD)")

        PayloadTLS.configureSocket(clientFD)

        guard let ctx = PayloadTLS.makeContext(isServer: true, fd: clientFD) else {
            finish(with: .failure(PayloadError.tlsHandshakeFailed(errSSLInternal)), onComplete: onComplete)
            return
        }
        stateLock.withLock { self.sslContext = ctx }

        let status = PayloadTLS.handshake(
            ctx,
            fd: clientFD,
            deadline: Date().addingTimeInterval(PayloadPort.handshakeTimeout),
            label: "server"
        )
        guard status == noErr else {
            finish(with: .failure(PayloadError.tlsHandshakeFailed(status)), onComplete: onComplete)
            return
        }
        guard PayloadTLS.verifyPeer(ctx, expected: expectedPeerFingerprint, label: "server") else {
            finish(with: .failure(PayloadError.certificateMismatch), onComplete: onComplete)
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            finish(with: .failure(PayloadError.fileUnreadable(fileURL)), onComplete: onComplete)
            return
        }
        defer { try? handle.close() }

        var sent: Int64 = 0
        var lastProgress = Date()
        while sent < size {
            if stateLock.withLock({ isFinished }) {
                finish(with: .failure(PayloadError.cancelled), onComplete: onComplete)
                return
            }

            let remaining = size - sent
            let want = Int(min(Int64(PayloadPort.chunkSize), remaining))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }

            let writeStatus = SocketTLS.writeAll(
                ctx,
                fd: clientFD,
                chunk,
                deadline: Date().addingTimeInterval(PayloadPort.ioStallTimeout)
            )
            guard writeStatus == noErr else {
                finish(with: .failure(PayloadError.socketFailure(writeStatus)), onComplete: onComplete)
                return
            }

            sent += Int64(chunk.count)
            let now = Date()
            if now.timeIntervalSince(lastProgress) > PayloadPort.ioStallTimeout {
                finish(with: .failure(PayloadError.connectionTimeout), onComplete: onComplete)
                return
            }
            lastProgress = now
            onProgress(Double(sent) / Double(size))
        }

        guard sent == size else {
            finish(with: .failure(PayloadError.peerClosedEarly(expected: size, received: sent)), onComplete: onComplete)
            return
        }

        TetherLog("[PayloadUploader] Sent \(sent) bytes for \(fileURL.lastPathComponent)")
        finish(with: .success(()), onComplete: onComplete)
    }

    public func cancel() {
        finish(with: .failure(PayloadError.cancelled)) { _ in }
    }

    private func finish(with result: Result<Void, Error>, onComplete: @escaping (Result<Void, Error>) -> Void) {
        typealias Teardown = (listen: Int32, client: Int32, ctx: SSLContext?)

        let teardown = stateLock.withLock { () -> Teardown? in
            guard !isFinished else { return nil }
            let snapshot: Teardown = (listenFD, acceptedFD, sslContext)
            isFinished = true
            listenFD = -1
            acceptedFD = -1
            sslContext = nil
            return snapshot
        }

        // Already torn down by a concurrent cancel() or completion — report nothing
        // so the completion handler is invoked exactly once.
        guard let teardown else { return }

        if teardown.listen >= 0 { Darwin.close(teardown.listen) }
        if let ctx = teardown.ctx {
            if case .success = result, teardown.client >= 0 {
                // Let the phone read the last bytes before the socket goes away.
                SocketTLS.closeGracefully(ctx, fd: teardown.client)
            } else {
                SSLClose(ctx)
            }
        }
        if teardown.client >= 0 { Darwin.close(teardown.client) }

        // Drop the self-retain, held in a local so the release happens outside the lock.
        let released = stateLock.withLock { () -> PayloadUploader? in
            let reference = selfReference
            selfReference = nil
            return reference
        }
        _ = released

        onComplete(result)
    }
}

// MARK: - Download (we receive a payload: we are the TLS client)

public enum PayloadDownloader {

    /// Where in-flight downloads are written before a plugin claims them.
    public static var incomingDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("TetherIncoming", isDirectory: true)
    }

    /// Stops a download in progress.
    public final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var fd: Int32 = -1

        var isCancelled: Bool { lock.withLock { cancelled } }

        func attach(_ fd: Int32) -> Bool {
            lock.withLock {
                self.fd = fd
                return !cancelled
            }
        }

        public func cancel() {
            lock.withLock {
                cancelled = true
                // Wakes a read that is waiting on the socket.
                if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
            }
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
    public static func download(
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
        guard var address = SocketAddress.make(host: host, port: port) else {
            return .failure(PayloadError.socketFailure(EINVAL))
        }
        let fd = socket(Int32(address.storage.ss_family), SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(PayloadError.socketFailure(errno)) }
        defer { Darwin.close(fd) }
        guard handle.attach(fd) else { return .failure(PayloadError.cancelled) }

        PayloadTLS.configureSocket(fd)

        let connectResult = withUnsafePointer(to: &address.storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, address.length)
            }
        }

        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                TetherLog("[PayloadDownloader] Connect to \(host):\(port) failed (errno \(errno))")
                return .failure(PayloadError.socketFailure(errno))
            }

            guard SocketTLS.wait(fd: fd, for: POLLOUT, until: Date().addingTimeInterval(PayloadPort.acceptTimeout)) else {
                return .failure(PayloadError.connectionTimeout)
            }

            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength)
            guard socketError == 0 else {
                TetherLog("[PayloadDownloader] Connect to \(host):\(port) failed (SO_ERROR \(socketError))")
                return .failure(PayloadError.socketFailure(socketError))
            }
        }

        TetherLog("[PayloadDownloader] TCP connected to \(host):\(port), starting TLS client handshake")

        guard let ctx = PayloadTLS.makeContext(isServer: false, fd: fd) else {
            return .failure(PayloadError.tlsHandshakeFailed(errSSLInternal))
        }
        defer { SSLClose(ctx) }

        let status = PayloadTLS.handshake(
            ctx,
            fd: fd,
            deadline: Date().addingTimeInterval(PayloadPort.handshakeTimeout),
            label: "client"
        )
        guard status == noErr else {
            TetherLog("[PayloadDownloader] TLS handshake failed with status \(status)")
            return .failure(PayloadError.tlsHandshakeFailed(status))
        }
        guard PayloadTLS.verifyPeer(ctx, expected: expectedPeerFingerprint, label: "client") else {
            return .failure(PayloadError.certificateMismatch)
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else {
            return .failure(PayloadError.fileUnwritable(destination))
        }
        defer { try? output.close() }

        var received: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: PayloadPort.chunkSize)
        var lastProgress = Date()
        var lastReported = 0.0

        let isSizeKnown = size > 0
        while !isSizeKnown || received < size {
            if handle.isCancelled { return .failure(PayloadError.cancelled) }
            var bytesRead = 0
            let remaining = isSizeKnown ? Int(min(Int64(buffer.count), size - received)) : buffer.count
            let readStatus = SSLRead(ctx, &buffer, remaining, &bytesRead)

            if bytesRead > 0 {
                do {
                    try output.write(contentsOf: Data(bytes: buffer, count: bytesRead))
                } catch {
                    return .failure(PayloadError.fileUnwritable(destination))
                }
                received += Int64(bytesRead)
                lastProgress = Date()

                // Throttle progress callbacks to whole percents.
                guard isSizeKnown else { continue }
                let fraction = Double(received) / Double(size)
                if fraction - lastReported >= 0.01 || received == size {
                    lastReported = fraction
                    onProgress(fraction)
                }
                continue
            }

            switch readStatus {
            case errSSLWouldBlock, errSSLPeerAuthCompleted:
                let stallDeadline = lastProgress.addingTimeInterval(PayloadPort.ioStallTimeout)
                guard SocketTLS.wait(fd: fd, for: POLLIN, until: stallDeadline) else {
                    TetherLog("[PayloadDownloader] Stalled after \(received)/\(size) bytes")
                    return .failure(PayloadError.connectionTimeout)
                }
                continue
            case noErr:
                break
            case errSSLClosedGraceful where !isSizeKnown, errSSLClosedNoNotify where !isSizeKnown:
                // The end of a file of unknown size.
                TetherLog("[PayloadDownloader] Received \(received) bytes (size not announced) from \(host):\(port)")
                return .success(destination)
            default:
                if handle.isCancelled { return .failure(PayloadError.cancelled) }
                TetherLog("[PayloadDownloader] Read failed with status \(readStatus)")
                return .failure(PayloadError.peerClosedEarly(expected: size, received: received))
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
