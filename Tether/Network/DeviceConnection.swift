//
//  DeviceConnection.swift
//  Tether
//

import Foundation
import Security
import Darwin
import CryptoKit

private func kdeSSLRead(connection: SSLConnectionRef, data: UnsafeMutableRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(bitPattern: UInt32(UInt(bitPattern: connection)))
    let requested = dataLength.pointee
    var totalRead = 0
    var ptr = data

    while totalRead < requested {
        let n = Darwin.read(fd, ptr, requested - totalRead)
        if n > 0 {
            totalRead += n
            ptr = ptr.advanced(by: n)
        } else if n == 0 {
            // EOF: peer closed socket
            dataLength.pointee = totalRead
            return totalRead == requested ? noErr : (totalRead > 0 ? OSStatus(errSSLWouldBlock) : OSStatus(errSSLClosedGraceful))
        } else {
            let err = errno
            if err == EINTR {
                continue
            }
            if err == EAGAIN || err == EWOULDBLOCK {
                // If we already started reading a TLS record, wait briefly for remaining segment
                if totalRead > 0 {
                    var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let pollRes = Darwin.poll(&pollFd, 1, 10)
                    if pollRes > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                        continue
                    }
                }
                dataLength.pointee = totalRead
                return OSStatus(errSSLWouldBlock)
            } else if err == ECONNRESET || err == EPIPE || err == ENOTCONN || err == ESHUTDOWN {
                dataLength.pointee = totalRead
                return totalRead > 0 ? OSStatus(errSSLWouldBlock) : OSStatus(errSSLClosedGraceful)
            }
            dataLength.pointee = totalRead
            return OSStatus(errSSLClosedAbort)
        }
    }

    dataLength.pointee = totalRead
    return noErr
}

private func kdeSSLWrite(connection: SSLConnectionRef, data: UnsafeRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(bitPattern: UInt32(UInt(bitPattern: connection)))
    let requested = dataLength.pointee
    var totalWritten = 0
    var ptr = data

    while totalWritten < requested {
        let n = Darwin.write(fd, ptr, requested - totalWritten)
        if n > 0 {
            totalWritten += n
            ptr = ptr.advanced(by: n)
        } else if n == 0 {
            dataLength.pointee = totalWritten
            return totalWritten == requested ? noErr : OSStatus(errSSLClosedGraceful)
        } else {
            let err = errno
            if err == EINTR {
                continue
            }
            if err == EAGAIN || err == EWOULDBLOCK {
                if totalWritten > 0 {
                    var pollFd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let pollRes = Darwin.poll(&pollFd, 1, 10)
                    if pollRes > 0 && (pollFd.revents & Int16(POLLOUT)) != 0 {
                        continue
                    }
                }
                dataLength.pointee = totalWritten
                return OSStatus(errSSLWouldBlock)
            } else if err == EPIPE || err == ECONNRESET || err == ESHUTDOWN {
                dataLength.pointee = totalWritten
                return OSStatus(errSSLClosedGraceful)
            }
            dataLength.pointee = totalWritten
            return OSStatus(errSSLClosedAbort)
        }
    }

    dataLength.pointee = totalWritten
    return noErr
}

public protocol DeviceConnectionDelegate: AnyObject, Sendable {
    func deviceConnectionDidConnect(_ connection: DeviceConnection)
    func deviceConnectionDidDisconnect(_ connection: DeviceConnection, error: Error?)
    func deviceConnection(_ connection: DeviceConnection, didReceivePacket packet: NetworkPacket)
    func deviceConnection(_ connection: DeviceConnection, didUpdatePairState state: PairState)
}

public final class DeviceConnection: @unchecked Sendable {
    /// Upper bound for the plaintext identity line read before TLS starts.
    private static let maxIdentityLineBytes = 64 * 1024
    /// Upper bound for one JSON packet. Large SMS syncs reach a few MB; anything
    /// beyond this is a broken or hostile peer, and the stream cannot be resynced.
    private static let maxPacketBytes = 32 * 1024 * 1024
    private static let handshakeTimeout: TimeInterval = 10
    private static let writeTimeout: TimeInterval = 15

    public let host: String
    public let port: Int
    public let isOutgoing: Bool
    public var targetDeviceId: String?

    public private(set) var peerDeviceInfo: DeviceInfo?
    public private(set) var peerCertificateFingerprint: String?
    public private(set) var pairState: PairState = .notPaired
    /// Set when the peer claims a paired device ID but presents a different
    /// certificate than the one pinned at pairing time.
    public private(set) var hasCertificateMismatch = false
    public var isDisconnected: Bool { isClosed }

    public weak var delegate: DeviceConnectionDelegate?
    public var pendingPairingRequest = false

    private var socketFD: Int32 = -1
    private var sslContext: SSLContext?
    private var readSource: DispatchSourceRead?
    private let connectionQueue: DispatchQueue
    private var readBuffer = Data()
    /// How far readBuffer has been searched for a line end, so a large packet
    /// arriving in pieces is scanned once, not once per piece.
    private var scannedBytes = 0
    /// Reused for every read on the connection's queue.
    private var readChunk = [UInt8](repeating: 0, count: 64 * 1024)
    private var isEncrypted = false
    private let lock = NSLock()
    private var isClosed = false

    public init(host: String, port: Int, targetDeviceId: String? = nil, isOutgoing: Bool) {
        self.host = host
        self.port = port
        self.targetDeviceId = targetDeviceId
        self.isOutgoing = isOutgoing
        self.connectionQueue = DispatchQueue(label: "com.subhashh.tether.conn.\(host):\(port)", qos: .userInitiated)
    }

    public init(socketFD: Int32, host: String, port: Int) {
        self.host = host
        self.port = port
        self.isOutgoing = false
        self.socketFD = socketFD
        self.connectionQueue = DispatchQueue(label: "com.subhashh.tether.conn.in.\(host):\(port)", qos: .userInitiated)

        var nosigpipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        SocketTLS.detectDeadPeerQuickly(socketFD)
    }

    deinit {
        TetherLog("[DeviceConnection] Deallocating connection for \(host):\(port)")
        cleanupSocket()
    }

    public func connect() {
        connectionQueue.async { [self] in
            if self.isOutgoing {
                self.performOutgoingConnection()
            } else {
                self.performIncomingHandshake()
            }
        }
    }

    private func performOutgoingConnection() {
        TetherLog("[DeviceConnection] Initiating outgoing TCP connection to \(host):\(port)")
        guard let tcpPort = in_port_t(exactly: port), tcpPort != 0 else {
            TetherLog("[DeviceConnection] Invalid port: \(port)")
            self.notifyDisconnect(error: nil)
            return
        }
        guard var address = SocketAddress.make(host: host, port: tcpPort) else {
            TetherLog("[DeviceConnection] Invalid IP address: \(host)")
            self.notifyDisconnect(error: nil)
            return
        }
        let fd = socket(Int32(address.storage.ss_family), SOCK_STREAM, 0)
        guard fd >= 0 else {
            TetherLog("[DeviceConnection] Failed to create socket: \(errno)")
            self.notifyDisconnect(error: nil)
            return
        }

        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        SocketTLS.detectDeadPeerQuickly(fd)

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connectResult = withUnsafePointer(to: &address.storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, address.length)
            }
        }

        guard connectResult == 0 else {
            TetherLog("[DeviceConnection] Failed to connect to \(host):\(port) (errno: \(errno))")
            close(fd)
            self.notifyDisconnect(error: nil)
            return
        }

        self.socketFD = fd
        TetherLog("[DeviceConnection] TCP connection established to \(host):\(port)")

        // Send initial plaintext connection packet
        guard let targetId = targetDeviceId else {
            TetherLog("[DeviceConnection] Missing targetDeviceId for outgoing connection")
            self.disconnect()
            return
        }

        let plainPacket = DeviceIdentity.shared.toDeviceInfo()
            .toConnectionPacket(targetDeviceId: targetId, targetProtocolVersion: NetworkPacket.protocolVersion)

        guard let data = try? plainPacket.serialize() else {
            self.disconnect()
            return
        }

        TetherLog("[DeviceConnection] Sending initial plaintext connection packet to \(host):\(port)")
        let bytesWritten = data.withUnsafeBytes { rawBuffer in
            Darwin.write(fd, rawBuffer.baseAddress, data.count)
        }

        guard bytesWritten == data.count else {
            TetherLog("[DeviceConnection] Failed to write initial connection packet")
            self.disconnect()
            return
        }

        // Outbound connection starts SSL in SERVER mode (KDE Connect v8 protocol inversion)
        self.startTLS(isServer: true)
    }

    private func performIncomingHandshake() {
        TetherLog("[DeviceConnection] Handling incoming connection from \(host):\(port)")
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read initial plaintext connection packet byte-by-byte so we NEVER consume TLS bytes
        var lineData = Data()
        var byte: UInt8 = 0

        while Darwin.read(socketFD, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") {
                break
            }
            lineData.append(byte)
            if lineData.count > Self.maxIdentityLineBytes {
                TetherLog("[DeviceConnection] Identity line from \(host) exceeded \(Self.maxIdentityLineBytes) bytes; dropping")
                disconnect()
                return
            }
        }

        if let packet = try? NetworkPacket.unserialize(from: lineData) {
            TetherLog("[DeviceConnection] Received incoming plaintext connection packet from \(packet.string(for: "deviceId") ?? "unknown")")
            self.targetDeviceId = packet.string(for: "deviceId")
        } else {
            TetherLog("[DeviceConnection] Failed to parse incoming connection packet: \(String(data: lineData, encoding: .utf8) ?? "")")
        }

        // Incoming connection starts SSL in CLIENT mode (KDE Connect v8 protocol inversion)
        self.startTLS(isServer: false)
    }

    private func startTLS(isServer: Bool) {
        TetherLog("[DeviceConnection] Starting TLS handshake (isServer: \(isServer)) on socket \(socketFD)")

        // Set non-blocking on socket so handshake uses polling with deadline
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        guard let ctx = SSLCreateContext(kCFAllocatorDefault, isServer ? .serverSide : .clientSide, .streamType) else {
            TetherLog("[DeviceConnection] Failed to create SSLContext")
            disconnect()
            return
        }

        SSLSetIOFuncs(ctx, kdeSSLRead, kdeSSLWrite)
        SSLSetConnection(ctx, SSLConnectionRef(bitPattern: UInt(UInt32(bitPattern: socketFD))))
        SSLSetCertificate(ctx, [DeviceIdentity.shared.secIdentity] as CFArray)
        if isServer {
            SSLSetClientSideAuthenticate(ctx, .alwaysAuthenticate)
            SSLSetSessionOption(ctx, .breakOnClientAuth, true)
        } else {
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)
            SSLSetSessionOption(ctx, .breakOnCertRequested, true)
        }

        let status = SocketTLS.handshake(ctx, fd: socketFD, deadline: Date().addingTimeInterval(Self.handshakeTimeout))

        guard status == noErr else {
            TetherLog("[DeviceConnection] TLS Handshake failed with status: \(status)")
            disconnect()
            return
        }

        self.sslContext = ctx
        self.isEncrypted = true
        TetherLog("[DeviceConnection] TLS Handshake completed successfully! (isServer: \(isServer))")

        extractPeerCertificate()
        setupReadSource()

        // Send full encrypted identity packet
        let fullIdentity = DeviceIdentity.shared.toDeviceInfo().toFullIdentityPacket()
        send(packet: fullIdentity)
    }

    private func setupReadSource() {
        guard socketFD >= 0 else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: connectionQueue)
        source.setEventHandler { [weak self] in
            self?.readIncomingEncrypted()
        }
        source.setCancelHandler { [weak self] in
            self?.cleanupSocket()
        }
        source.resume()
        self.readSource = source
    }

    private func readIncomingEncrypted() {
        guard let ctx = sslContext, !isClosed else { return }

        while true {
            var bytesRead: Int = 0
            let status = SSLRead(ctx, &readChunk, readChunk.count, &bytesRead)

            if bytesRead > 0 {
                lock.withLock {
                    readBuffer.append(readChunk, count: bytesRead)
                }
                processReadBuffer()
                // Whatever is left is an incomplete packet. If it is already too big
                // the peer is broken; clearing it would desync the stream, so drop
                // the connection instead.
                let pending = lock.withLock { readBuffer.count }
                if pending > Self.maxPacketBytes {
                    TetherLog("[DeviceConnection] Packet from \(host) exceeded \(Self.maxPacketBytes) bytes without a terminator; disconnecting")
                    disconnect()
                    return
                }
            }

            if status == errSSLWouldBlock {
                break
            }

            if status == errSSLClosedGraceful || status == errSSLClosedAbort {
                TetherLog("[DeviceConnection] SSL connection closed gracefully/aborted by peer (status: \(status)) on socket \(socketFD)")
                disconnect()
                return
            }

            if status != noErr {
                TetherLog("[DeviceConnection] SSLRead error: \(status) on socket \(socketFD)")
                disconnect()
                return
            }

            if bytesRead == 0 {
                break
            }
        }
    }

    private func processReadBuffer() {
        var linesToProcess: [Data] = []
        lock.withLock {
            // Only bytes not yet searched, and what's been read is removed
            // once at the end rather than shifting the buffer per line.
            var lineStart = readBuffer.startIndex
            var searchFrom = readBuffer.startIndex + scannedBytes
            while let newline = readBuffer[searchFrom...].firstIndex(of: UInt8(ascii: "\n")) {
                if newline > lineStart { linesToProcess.append(readBuffer.subdata(in: lineStart..<newline)) }
                lineStart = newline + 1
                searchFrom = lineStart
            }
            readBuffer.removeSubrange(readBuffer.startIndex..<lineStart)
            scannedBytes = readBuffer.count
        }

        for lineData in linesToProcess {
            do {
                let packet = try NetworkPacket.unserialize(from: lineData)
                handlePacket(packet)
            } catch {
                TetherLog("[DeviceConnection] Failed to parse JSON packet: \(error)")
            }
        }
    }

    private func handlePacket(_ packet: NetworkPacket) {
        // Handshake stage: receiving full encrypted identity
        if peerDeviceInfo == nil, packet.type == "kdeconnect.identity" {
            if let info = DeviceInfo.from(packet: packet) {
                self.peerDeviceInfo = info
                checkTrustStatus()
                TetherLog("[DeviceConnection] Received full identity from \(info.deviceName) (\(info.deviceId))")
                delegate?.deviceConnectionDidConnect(self)

                if self.pendingPairingRequest && self.pairState != .paired {
                    self.pendingPairingRequest = false
                    self.requestPairing()
                }
                return
            }
        }

        // Handle pairing packet
        if packet.type == "kdeconnect.pair" {
            handlePairPacket(packet)
            return
        }

        // Everything else is plugin traffic, which only a verified, paired peer may send.
        guard pairState == .paired else {
            TetherLog("[DeviceConnection] Dropping \(packet.type) from unpaired peer \(host)")
            return
        }
        delegate?.deviceConnection(self, didReceivePacket: packet)
    }

    private func extractPeerCertificate() {
        guard let ctx = sslContext, let fingerprint = SocketTLS.peerFingerprint(ctx) else {
            TetherLog("[DeviceConnection] Warning: could not read the peer certificate from \(host)")
            return
        }
        self.peerCertificateFingerprint = fingerprint
        TetherLog("[DeviceConnection] Peer certificate fingerprint: \(fingerprint)")
    }

    /// A device is paired only if its ID is in the trust store *and* it presented
    /// the exact certificate pinned when it was paired. The ID alone is broadcast
    /// in clear over UDP, so it proves nothing.
    private func checkTrustStatus() {
        guard let info = peerDeviceInfo else { return }
        guard let paired = TrustStore.shared.pairedDevice(for: info.deviceId) else {
            self.pairState = .notPaired
            TetherLog("[DeviceConnection] Device \(info.deviceName) is not paired")
            delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
            return
        }

        if SocketTLS.fingerprintsMatch(peerCertificateFingerprint, paired.certificateFingerprint) {
            self.pairState = .paired
            TrustStore.shared.updateLastSeen(deviceId: info.deviceId)
            TetherLog("[DeviceConnection] Device \(info.deviceName) is paired (certificate verified)")
            delegate?.deviceConnection(self, didUpdatePairState: .paired)
        } else {
            self.pairState = .notPaired
            self.hasCertificateMismatch = true
            TetherLog("[DeviceConnection] Refusing \(info.deviceName) (\(info.deviceId)): certificate \(peerCertificateFingerprint ?? "none") does not match the pinned one")
            delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
        }
    }

    /// How far apart the two clocks may be for a pairing request to count, as in
    /// KDE Connect. A request replayed later carries an old timestamp.
    private static let allowedPairClockDifference: Int64 = 30 * 60
    /// A pairing request nobody answers is dropped after this long.
    private static let pairingTimeout: TimeInterval = 30
    private var pairingTimeoutWork: DispatchWorkItem?

    // Follows KDE Connect's pairing rules: requests carry a timestamp, accepts
    // don't. Sending a timestamp in an accept makes an already paired peer
    // treat it as a new request and unpair.
    private func handlePairPacket(_ packet: NetworkPacket) {
        let wantsPair = packet.bool(for: "pair", default: false)
        guard let info = peerDeviceInfo else { return }

        TetherLog("[DeviceConnection] Received pair packet (wantsPair: \(wantsPair), currentState: \(pairState))")

        if wantsPair {
            switch pairState {
            case .requested:
                // We asked and they accepted.
                cancelPairingTimeout()
                completePairing()
            case .requestedByPeer:
                TetherLog("[DeviceConnection] Ignoring a second pairing request before the first one timed out")
            case .paired:
                // A request from a paired device means it forgot this Mac, for
                // example after KDE Connect was reinstalled. Its certificate was
                // verified, so this is the real device: start over.
                guard packet.has("timestamp") else {
                    TetherLog("[DeviceConnection] Ignoring a pairing accept from a device already paired")
                    return
                }
                TetherLog("[DeviceConnection] \(info.deviceName) asked to pair again; it no longer trusts this Mac")
                TrustStore.shared.remove(deviceId: info.deviceId, reason: "the device asked to pair again")
                pairState = .notPaired
                delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
                receivePairingRequest(packet, from: info)
            case .notPaired:
                receivePairingRequest(packet, from: info)
            }
        } else {
            // Unpair, reject or cancel. Only a verified peer may revoke its own
            // trust entry, otherwise anyone spoofing the device ID could unpair
            // the real phone.
            cancelPairingTimeout()
            switch pairState {
            case .notPaired:
                TetherLog("[DeviceConnection] Ignoring an unpair request from a device that isn't paired")
                return
            case .requested:
                TetherLog("[DeviceConnection] \(info.deviceName) declined pairing")
            case .requestedByPeer:
                TetherLog("[DeviceConnection] \(info.deviceName) cancelled its pairing request")
            case .paired:
                TetherLog("[DeviceConnection] \(info.deviceName) unpaired from this Mac")
                TrustStore.shared.remove(deviceId: info.deviceId, reason: "the device unpaired from this Mac")
            }
            self.pairState = .notPaired
            delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
            connectionQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.disconnect()
            }
        }
    }

    private func receivePairingRequest(_ packet: NetworkPacket, from info: DeviceInfo) {
        let timestamp = packet.int64(for: "timestamp")
        guard timestamp > 0 else {
            TetherLog("[DeviceConnection] Ignoring a pairing request without a timestamp from \(info.deviceName)")
            return
        }
        let now = Int64(Date().timeIntervalSince1970)
        guard abs(timestamp - now) <= Self.allowedPairClockDifference else {
            TetherLog("[DeviceConnection] Ignoring a pairing request from \(info.deviceName): the clocks differ by \(abs(timestamp - now)) seconds")
            return
        }
        pairState = .requestedByPeer
        startPairingTimeout()
        delegate?.deviceConnection(self, didUpdatePairState: .requestedByPeer)
    }

    private func startPairingTimeout() {
        cancelPairingTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pairState == .requested || self.pairState == .requestedByPeer else { return }
            TetherLog("[DeviceConnection] Pairing with \(self.peerDeviceInfo?.deviceName ?? "peer") timed out")
            self.pairState = .notPaired
            self.delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
        }
        pairingTimeoutWork = work
        connectionQueue.asyncAfter(deadline: .now() + Self.pairingTimeout, execute: work)
    }

    private func cancelPairingTimeout() {
        pairingTimeoutWork?.cancel()
        pairingTimeoutWork = nil
    }

    public func requestPairing() {
        guard isEncrypted else {
            TetherLog("[DeviceConnection] TLS not ready yet, queuing pairing request")
            pendingPairingRequest = true
            return
        }
        TetherLog("[DeviceConnection] Sending pair request to \(peerDeviceInfo?.deviceName ?? "peer")")
        if pairState == .requestedByPeer {
            // They asked first: answering is accepting.
            acceptPairing()
            return
        }
        guard pairState == .notPaired else { return }
        self.pairState = .requested
        startPairingTimeout()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let packet = NetworkPacket(
            type: "kdeconnect.pair",
            body: [
                "pair": true,
                "timestamp": timestamp
            ]
        )
        send(packet: packet)
        delegate?.deviceConnection(self, didUpdatePairState: .requested)
    }

    public func acceptPairing() {
        guard pairState == .requestedByPeer else {
            TetherLog("[DeviceConnection] No pairing request to accept from \(peerDeviceInfo?.deviceName ?? "peer"); it may have timed out")
            return
        }
        TetherLog("[DeviceConnection] Accepting pairing request from \(peerDeviceInfo?.deviceName ?? "peer")")
        cancelPairingTimeout()
        // An accept carries no timestamp; see handlePairPacket.
        send(packet: NetworkPacket(type: "kdeconnect.pair", body: ["pair": true]))
        completePairing()
    }

    public func rejectPairing() {
        TetherLog("[DeviceConnection] Rejecting pairing request from \(peerDeviceInfo?.deviceName ?? "peer")")
        cancelPairingTimeout()
        let packet = NetworkPacket(type: "kdeconnect.pair", body: ["pair": false])
        send(packet: packet)
        self.pairState = .notPaired
        delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
        connectionQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.disconnect()
        }
    }

    public func unpair() {
        guard let info = peerDeviceInfo else { return }
        TetherLog("[DeviceConnection] Unpairing from \(info.deviceName)")
        let packet = NetworkPacket(type: "kdeconnect.pair", body: ["pair": false])
        send(packet: packet)
        self.pairState = .notPaired
        TrustStore.shared.remove(deviceId: info.deviceId, reason: "unpaired on this Mac while connected")
        delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
        connectionQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.disconnect()
        }
    }

    private func completePairing() {
        guard let info = peerDeviceInfo else {
            TetherLog("[DeviceConnection] Cannot complete pairing: peerDeviceInfo is nil")
            return
        }

        guard let fingerprint = peerCertificateFingerprint, !fingerprint.isEmpty else {
            TetherLog("[DeviceConnection] Cannot complete pairing: no peer certificate to pin")
            rejectPairing()
            return
        }
        self.pairState = .paired
        self.hasCertificateMismatch = false
        let pairedDevice = PairedDevice(
            deviceId: info.deviceId,
            deviceName: info.deviceName,
            deviceType: info.deviceType,
            certificateFingerprint: fingerprint,
            certificatePEM: nil
        )
        TrustStore.shared.add(device: pairedDevice)
        delegate?.deviceConnection(self, didUpdatePairState: .paired)
        TetherLog("[DeviceConnection] Pairing completed successfully with \(info.deviceName) (\(info.deviceId))")
    }

    // Safe from any thread: it only queues the write on connectionQueue. Kept off
    // the main actor so serving the phone drive never needs the main thread.
    nonisolated public func send(packet: NetworkPacket) {
        guard let data = try? packet.serialize() else { return }
        connectionQueue.async { [weak self] in
            guard let self, let ctx = self.sslContext, !self.isClosed else { return }

            let status = SocketTLS.writeAll(ctx, fd: self.socketFD, data, deadline: Date().addingTimeInterval(Self.writeTimeout))
            if status != noErr {
                // A partial packet has been written; the stream is unusable now.
                TetherLog("[DeviceConnection] SSLWrite of \(packet.type) failed with status \(status); disconnecting")
                self.disconnect()
            }
        }
    }

    public func disconnect() {
        connectionQueue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.isClosed = true

            TetherLog("[DeviceConnection] Disconnecting from \(self.host):\(self.port)")

            if let source = self.readSource {
                source.cancel()
                self.readSource = nil
            } else {
                self.cleanupSocket()
            }

            self.notifyDisconnect(error: nil)
        }
    }

    private func cleanupSocket() {
        if let ctx = sslContext {
            SSLClose(ctx)
            self.sslContext = nil
        }
        if socketFD >= 0 {
            close(socketFD)
            self.socketFD = -1
        }
    }

    private func notifyDisconnect(error: Error?) {
        delegate?.deviceConnectionDidDisconnect(self, error: error)
    }
}
