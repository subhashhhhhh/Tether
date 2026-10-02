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

    /// Budget for the TLS handshake.
    ///
    /// Deliberately large: the first server-side handshake in a fresh process can
    /// spend ~25s evaluating the peer's self-signed certificate before completing.
    /// In the running app the identity and trust state are already warm from
    /// pairing, so a payload handshake normally finishes in milliseconds — this is
    /// purely a safety net for the cold path.
    public static let handshakeTimeout: TimeInterval = 60

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
    static func handshake(_ ctx: SSLContext, deadline: Date, label: String) -> OSStatus {
        var status: OSStatus = errSSLWouldBlock
        var iterations = 0
        while status == errSSLWouldBlock
            || status == errSSLPeerAuthCompleted
            || status == errSSLClientCertRequested {
            if Date() > deadline {
                TetherLog("[PayloadTLS] \(label) handshake exceeded deadline after \(iterations) iterations (last status \(status))")
                return errSSLWouldBlock
            }
            status = SSLHandshake(ctx)
            iterations += 1
            if iterations <= 8 {
                TetherLog("[PayloadTLS] \(label) SSLHandshake #\(iterations) -> \(status)")
            }
            if status == errSSLWouldBlock { usleep(2000) }
        }
        TetherLog("[PayloadTLS] \(label) handshake ok after \(iterations) iterations")
        return status
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

    /// Writes the whole buffer, re-driving on would-block until the deadline.
    ///
    /// SecureTransport routinely reports `errSSLWouldBlock` *together with* a
    /// positive byte count, so a fully-drained buffer is success regardless of
    /// the status that accompanied the final write.
    static func writeAll(_ ctx: SSLContext, _ data: Data, deadline: Date) -> OSStatus {
        var status: OSStatus = noErr
        data.withUnsafeBytes { raw in
            guard var ptr = raw.baseAddress else { return }
            var remaining = data.count
            while remaining > 0 {
                if Date() > deadline {
                    status = errSSLWouldBlock
                    return
                }
                var written = 0
                status = SSLWrite(ctx, ptr, remaining, &written)
                if written > 0 {
                    remaining -= written
                    ptr = ptr.advanced(by: written)
                }
                if remaining == 0 {
                    status = noErr
                    return
                }
                if status == errSSLWouldBlock {
                    usleep(2000)
                    continue
                }
                if status != noErr { return }
            }
        }
        return status
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
            self?.acceptAndStream(fileURL: fileURL, size: size, onProgress: onProgress, onComplete: onComplete)
        }
    }

    private static func makeListeningSocket(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    private func acceptAndStream(
        fileURL: URL,
        size: Int64,
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

        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.accept(listenSocket, sockaddrPointer, &addrLen)
            }
        }

        guard clientFD >= 0 else {
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
            deadline: Date().addingTimeInterval(PayloadPort.handshakeTimeout),
            label: "server"
        )
        guard status == noErr else {
            finish(with: .failure(PayloadError.tlsHandshakeFailed(status)), onComplete: onComplete)
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

            let writeStatus = PayloadTLS.writeAll(
                ctx,
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

        if let ctx = teardown.ctx { SSLClose(ctx) }
        if teardown.listen >= 0 { Darwin.close(teardown.listen) }
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

    /// Connects to the peer's payload server and reads `size` bytes.
    ///
    /// - Parameters:
    ///   - host: Address of the peer that announced the transfer.
    ///   - port: Port taken from `payloadTransferInfo["port"]`.
    ///   - size: Expected byte count from the packet's `payloadSize`.
    public static func download(
        host: String,
        port: UInt16,
        size: Int64,
        onProgress: @escaping (Double) -> Void = { _ in },
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performDownload(host: host, port: port, size: size, onProgress: onProgress)
            completion(result)
        }
    }

    private static func performDownload(
        host: String,
        port: UInt16,
        size: Int64,
        onProgress: @escaping (Double) -> Void
    ) -> Result<Data, Error> {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(PayloadError.socketFailure(errno)) }
        defer { Darwin.close(fd) }

        PayloadTLS.configureSocket(fd)

        var (addr, addrLen) = makeSockaddr(host: host, port: port)
        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, addrLen)
            }
        }

        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                TetherLog("[PayloadDownloader] Connect to \(host):\(port) failed (errno \(errno))")
                return .failure(PayloadError.socketFailure(errno))
            }

            var pollFd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollResult = Darwin.poll(&pollFd, 1, Int32(PayloadPort.acceptTimeout * 1000))
            guard pollResult > 0 else {
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
            deadline: Date().addingTimeInterval(PayloadPort.handshakeTimeout),
            label: "client"
        )
        guard status == noErr else {
            TetherLog("[PayloadDownloader] TLS handshake failed with status \(status)")
            return .failure(PayloadError.tlsHandshakeFailed(status))
        }

        var received = Data()
        if size > 0 { received.reserveCapacity(Int(min(size, 32 * 1024 * 1024))) }

        var buffer = [UInt8](repeating: 0, count: PayloadPort.chunkSize)
        var lastProgress = Date()

        while Int64(received.count) < size {
            var bytesRead = 0
            let remaining = Int(min(Int64(buffer.count), size - Int64(received.count)))
            let readStatus = SSLRead(ctx, &buffer, remaining, &bytesRead)

            if bytesRead > 0 {
                received.append(buffer, count: bytesRead)
                lastProgress = Date()
                onProgress(Double(received.count) / Double(size))
                continue
            }

            switch readStatus {
            case errSSLWouldBlock, errSSLPeerAuthCompleted:
                if Date().timeIntervalSince(lastProgress) > PayloadPort.ioStallTimeout {
                    TetherLog("[PayloadDownloader] Stalled after \(received.count)/\(size) bytes")
                    return .failure(PayloadError.connectionTimeout)
                }
                usleep(2000)
                continue
            case noErr:
                break
            default:
                TetherLog("[PayloadDownloader] Read failed with status \(readStatus)")
                return .failure(PayloadError.peerClosedEarly(expected: size, received: Int64(received.count)))
            }
            break
        }

        guard Int64(received.count) == size else {
            TetherLog("[PayloadDownloader] Incomplete payload: \(received.count)/\(size) bytes")
            return .failure(PayloadError.peerClosedEarly(expected: size, received: Int64(received.count)))
        }

        TetherLog("[PayloadDownloader] Received \(received.count) bytes from \(host):\(port)")
        return .success(received)
    }

    private static func makeSockaddr(host: String, port: UInt16) -> (sockaddr_in, socklen_t) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        return (addr, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
