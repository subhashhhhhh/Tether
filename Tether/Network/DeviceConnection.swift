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
    public let host: String
    public let port: Int
    public let isOutgoing: Bool
    public var targetDeviceId: String?

    public private(set) var peerDeviceInfo: DeviceInfo?
    public private(set) var peerCertificateFingerprint: String?
    public private(set) var pairState: PairState = .notPaired
    public var isDisconnected: Bool { isClosed }

    public weak var delegate: DeviceConnectionDelegate?
    public var pendingPairingRequest = false

    private var socketFD: Int32 = -1
    private var sslContext: SSLContext?
    private var readSource: DispatchSourceRead?
    private let connectionQueue: DispatchQueue
    private var readBuffer = Data()
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
        var keepalive: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_KEEPALIVE, &keepalive, socklen_t(MemoryLayout<Int32>.size))
        var keepaliveTime: Int32 = 10
        setsockopt(socketFD, IPPROTO_TCP, TCP_KEEPALIVE, &keepaliveTime, socklen_t(MemoryLayout<Int32>.size))
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
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            TetherLog("[DeviceConnection] Failed to create socket: \(errno)")
            self.notifyDisconnect(error: nil)
            return
        }

        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var keepalive: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &keepalive, socklen_t(MemoryLayout<Int32>.size))
        var keepaliveTime: Int32 = 10
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepaliveTime, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) <= 0 {
            TetherLog("[DeviceConnection] Invalid IP address: \(host)")
            close(fd)
            self.notifyDisconnect(error: nil)
            return
        }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
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

        let plainPacket = DeviceIdentity.shared.toDeviceInfo(tcpPort: 1716)
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

        var status: OSStatus = errSSLWouldBlock
        let deadline = Date().addingTimeInterval(5.0)

        while status == errSSLWouldBlock || status == errSSLPeerAuthCompleted || status == errSSLClientCertRequested {
            if Date() > deadline {
                TetherLog("[DeviceConnection] TLS Handshake timed out (status: \(status))")
                disconnect()
                return
            }
            status = SSLHandshake(ctx)
            if status == errSSLWouldBlock {
                usleep(5000) // 5ms
            }
        }

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
        let fullIdentity = DeviceIdentity.shared.toDeviceInfo(tcpPort: 1716).toFullIdentityPacket()
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
            var buffer = [UInt8](repeating: 0, count: 8192)
            var bytesRead: Int = 0
            let status = SSLRead(ctx, &buffer, buffer.count, &bytesRead)

            if bytesRead > 0 {
                lock.withLock {
                    readBuffer.append(buffer, count: bytesRead)
                    if readBuffer.count > 1_000_000 {
                        readBuffer.removeAll()
                    }
                }
                processReadBuffer()
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
            while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = readBuffer.subdata(in: 0..<newlineIndex)
                readBuffer.removeSubrange(0...newlineIndex)
                if !lineData.isEmpty {
                    linesToProcess.append(lineData)
                }
            }
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

        // Dispatch other packets to delegate
        delegate?.deviceConnection(self, didReceivePacket: packet)
    }

    private func extractPeerCertificate() {
        guard let ctx = sslContext else { return }
        var trust: SecTrust?
        let status = SSLCopyPeerTrust(ctx, &trust)
        guard status == noErr, let t = trust else {
            TetherLog("[DeviceConnection] Warning: Could not copy peer trust (status: \(status))")
            return
        }

        var peerCert: SecCertificate?
        if let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let first = chain.first {
            peerCert = first
        } else {
            let count = SecTrustGetCertificateCount(t)
            if count > 0 {
                peerCert = SecTrustGetCertificateAtIndex(t, 0)
            }
        }

        guard let cert = peerCert else {
            TetherLog("[DeviceConnection] Warning: Could not copy peer certificate from trust chain (status: \(status))")
            return
        }

        let certData = SecCertificateCopyData(cert) as Data
        let digest = SHA256.hash(data: certData)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined(separator: ":")
        self.peerCertificateFingerprint = fingerprint
        TetherLog("[DeviceConnection] Peer certificate fingerprint: \(fingerprint)")
    }

    private func checkTrustStatus() {
        guard let info = peerDeviceInfo else { return }
        if TrustStore.shared.isTrusted(deviceId: info.deviceId) {
            self.pairState = .paired
            TetherLog("[DeviceConnection] Device \(info.deviceName) is trusted/paired")
            delegate?.deviceConnection(self, didUpdatePairState: .paired)
        } else {
            self.pairState = .notPaired
            TetherLog("[DeviceConnection] Device \(info.deviceName) is not paired")
            delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
        }
    }

    private func handlePairPacket(_ packet: NetworkPacket) {
        let wantsPair = packet.bool(for: "pair", default: false)
        guard let info = peerDeviceInfo else { return }

        TetherLog("[DeviceConnection] Received pair packet (wantsPair: \(wantsPair), currentState: \(pairState))")

        if wantsPair {
            switch pairState {
            case .requested:
                // We requested and they accepted!
                let timestamp = Int64(Date().timeIntervalSince1970)
                let confirmPacket = NetworkPacket(
                    type: "kdeconnect.pair",
                    body: [
                        "pair": true,
                        "timestamp": timestamp
                    ]
                )
                send(packet: confirmPacket)
                completePairing()
            case .notPaired:
                // They requested pairing with us
                self.pairState = .requestedByPeer
                delegate?.deviceConnection(self, didUpdatePairState: .requestedByPeer)
            case .paired:
                break
            case .requestedByPeer:
                break
            }
        } else {
            // Unpair / reject
            TetherLog("[DeviceConnection] Peer rejected or unpaired from us")
            self.pairState = .notPaired
            TrustStore.shared.remove(deviceId: info.deviceId)
            delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
            connectionQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.disconnect()
            }
        }
    }

    public func requestPairing() {
        guard isEncrypted else {
            TetherLog("[DeviceConnection] TLS not ready yet, queuing pairing request")
            pendingPairingRequest = true
            return
        }
        TetherLog("[DeviceConnection] Sending pair request to \(peerDeviceInfo?.deviceName ?? "peer")")
        self.pairState = .requested
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
        TetherLog("[DeviceConnection] Accepting pairing request from \(peerDeviceInfo?.deviceName ?? "peer")")
        let timestamp = Int64(Date().timeIntervalSince1970)
        let packet = NetworkPacket(
            type: "kdeconnect.pair",
            body: [
                "pair": true,
                "timestamp": timestamp
            ]
        )
        send(packet: packet)
        completePairing()
    }

    public func rejectPairing() {
        TetherLog("[DeviceConnection] Rejecting pairing request from \(peerDeviceInfo?.deviceName ?? "peer")")
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
        TrustStore.shared.remove(deviceId: info.deviceId)
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

        let fingerprint = peerCertificateFingerprint ?? TrustStore.shared.pairedDevice(for: info.deviceId)?.certificateFingerprint ?? ""
        self.pairState = .paired
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

    public func send(packet: NetworkPacket) {
        guard let data = try? packet.serialize() else { return }
        connectionQueue.async { [weak self] in
            guard let self = self, let ctx = self.sslContext else { return }

            data.withUnsafeBytes { rawBuffer in
                guard var ptr = rawBuffer.baseAddress else { return }
                var remaining = data.count
                var retries = 0

                while remaining > 0 && retries < 100 {
                    var written: Int = 0
                    let status = SSLWrite(ctx, ptr, remaining, &written)
                    if written > 0 {
                        remaining -= written
                        ptr = ptr.advanced(by: written)
                    }
                    if remaining == 0 { break }
                    if status == errSSLWouldBlock {
                        usleep(2000) // 2ms
                        retries += 1
                        continue
                    }
                    if status != noErr {
                        TetherLog("[DeviceConnection] SSLWrite failed with status \(status)")
                        break
                    }
                }
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
