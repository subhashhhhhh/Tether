//
//  DeviceConnection.swift
//  KDEConnect
//

import Foundation
import CoreFoundation
import Security
import CryptoKit

public protocol DeviceConnectionDelegate: AnyObject, Sendable {
    func deviceConnectionDidConnect(_ connection: DeviceConnection)
    func deviceConnectionDidDisconnect(_ connection: DeviceConnection, error: Error?)
    func deviceConnection(_ connection: DeviceConnection, didReceivePacket packet: NetworkPacket)
    func deviceConnection(_ connection: DeviceConnection, didUpdatePairState state: PairState)
}

public final class DeviceConnection: NSObject, StreamDelegate, @unchecked Sendable {
    public let host: String
    public let port: Int
    public let isOutgoing: Bool
    public var targetDeviceId: String?

    public private(set) var peerDeviceInfo: DeviceInfo?
    public private(set) var peerCertificateFingerprint: String?
    public private(set) var pairState: PairState = .notPaired

    public weak var delegate: DeviceConnectionDelegate?

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var readBuffer = Data()
    private var isEncrypted = false
    private var hasSentConnectionPacket = false
    private let queue = DispatchQueue(label: "org.kde.kdeconnect.connection", qos: .userInitiated)

    public init(host: String, port: Int, targetDeviceId: String? = nil, isOutgoing: Bool) {
        self.host = host
        self.port = port
        self.targetDeviceId = targetDeviceId
        self.isOutgoing = isOutgoing
        super.init()
    }

    public init(socketFD: Int32, host: String, port: Int) {
        self.host = host
        self.port = port
        self.isOutgoing = false
        super.init()

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketFD, &readStream, &writeStream)

        if let r = readStream?.takeRetainedValue(), let w = writeStream?.takeRetainedValue() {
            self.inputStream = r
            self.outputStream = w
        }
    }

    public func connect() {
        guard isOutgoing else {
            setupStreams()
            return
        }

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, host as CFString, UInt32(port), &readStream, &writeStream)

        guard let r = readStream?.takeRetainedValue(), let w = writeStream?.takeRetainedValue() else {
            print("[DeviceConnection] Failed to create streams to \(host):\(port)")
            return
        }

        self.inputStream = r
        self.outputStream = w
        setupStreams()
    }

    private func setupStreams() {
        guard let inputStream = inputStream, let outputStream = outputStream else { return }

        inputStream.delegate = self
        outputStream.delegate = self

        inputStream.schedule(in: .current, forMode: .default)
        outputStream.schedule(in: .current, forMode: .default)

        inputStream.open()
        outputStream.open()
    }

    public func disconnect() {
        inputStream?.close()
        outputStream?.close()
        inputStream?.remove(from: .current, forMode: .default)
        outputStream?.remove(from: .current, forMode: .default)
        inputStream = nil
        outputStream = nil
    }

    // StreamDelegate
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if isOutgoing && !hasSentConnectionPacket && aStream == outputStream {
                hasSentConnectionPacket = true
                sendInitialConnectionPacket()
            }
        case .hasBytesAvailable:
            if aStream == inputStream {
                readIncomingData()
            }
        case .errorOccurred:
            print("[DeviceConnection] Stream error: \(aStream.streamError?.localizedDescription ?? "unknown")")
            delegate?.deviceConnectionDidDisconnect(self, error: aStream.streamError)
            disconnect()
        case .endEncountered:
            delegate?.deviceConnectionDidDisconnect(self, error: nil)
            disconnect()
        default:
            break
        }
    }

    private func sendInitialConnectionPacket() {
        guard let targetId = targetDeviceId else { return }
        let packet = DeviceIdentity.shared.toDeviceInfo(tcpPort: 1716)
            .toConnectionPacket(targetDeviceId: targetId, targetProtocolVersion: NetworkPacket.protocolVersion)

        if let data = try? packet.serialize() {
            writeRaw(data: data)
            upgradeToTLS(isServer: true)
        }
    }

    private func upgradeToTLS(isServer: Bool) {
        guard let inputStream = inputStream, let outputStream = outputStream else { return }

        let sslSettings: [CFString: Any] = [
            kCFStreamSSLValidatesCertificateChain: false,
            kCFStreamSSLIsServer: isServer,
            kCFStreamSSLCertificates: [DeviceIdentity.shared.secIdentity]
        ]

        CFReadStreamSetProperty(inputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), sslSettings as CFTypeRef)
        CFWriteStreamSetProperty(outputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), sslSettings as CFTypeRef)

        self.isEncrypted = true
        print("[DeviceConnection] Upgraded connection to TLS (isServer: \(isServer))")

        // After TLS upgrade, send full identity packet
        let identityPacket = DeviceIdentity.shared.toDeviceInfo(tcpPort: 1716).toFullIdentityPacket()
        if let data = try? identityPacket.serialize() {
            writeRaw(data: data)
        }
    }

    private func readIncomingData() {
        guard let inputStream = inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)

        guard bytesRead > 0 else { return }
        readBuffer.append(buffer, count: bytesRead)

        processReadBuffer()
    }

    private func processReadBuffer() {
        while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer.subdata(in: 0..<newlineIndex)
            readBuffer.removeSubrange(0...newlineIndex)

            guard !lineData.isEmpty else { continue }
            handlePacketData(lineData)
        }
    }

    private func handlePacketData(_ data: Data) {
        guard let packet = try? NetworkPacket.unserialize(from: data) else {
            print("[DeviceConnection] Failed to decode packet: \(String(data: data, encoding: .utf8) ?? "")")
            return
        }

        if !isEncrypted {
            // Received plaintext connection packet on incoming connection
            if packet.type == "kdeconnect.identity" {
                self.targetDeviceId = packet.string(for: "deviceId")
                upgradeToTLS(isServer: false)
            }
            return
        }

        // Handshake stage: receiving full encrypted identity
        if peerDeviceInfo == nil, packet.type == "kdeconnect.identity" {
            if let info = DeviceInfo.from(packet: packet) {
                self.peerDeviceInfo = info
                extractPeerCertificate()
                checkTrustStatus()
                delegate?.deviceConnectionDidConnect(self)
                return
            }
        }

        // Handle pairing packet
        if packet.type == "kdeconnect.pair" {
            handlePairPacket(packet)
            return
        }

        delegate?.deviceConnection(self, didReceivePacket: packet)
    }

    private func extractPeerCertificate() {
        guard let inputStream = inputStream else { return }
        if let trust = CFReadStreamCopyProperty(inputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLPeerTrust)) {
            let secTrust = trust as! SecTrust
            if let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let peerCert = certChain.first {
                let certData = SecCertificateCopyData(peerCert) as Data
                let digest = SHA256.hash(data: certData)
                self.peerCertificateFingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
            }
        }
    }

    private func checkTrustStatus() {
        guard let deviceId = peerDeviceInfo?.deviceId else { return }
        if TrustStore.shared.isTrusted(deviceId: deviceId) {
            self.pairState = .paired
            TrustStore.shared.updateLastSeen(deviceId: deviceId)
        } else {
            self.pairState = .notPaired
        }
        delegate?.deviceConnection(self, didUpdatePairState: pairState)
    }

    private func handlePairPacket(_ packet: NetworkPacket) {
        let wantsPair = packet.bool(for: "pair")
        if wantsPair {
            switch pairState {
            case .requested:
                // We requested and they accepted!
                completePairing()
            case .notPaired:
                // They requested pairing with us
                self.pairState = .requestedByPeer
                delegate?.deviceConnection(self, didUpdatePairState: .requestedByPeer)
            default:
                break
            }
        } else {
            // Unpair or reject
            self.pairState = .notPaired
            if let id = peerDeviceInfo?.deviceId {
                TrustStore.shared.remove(deviceId: id)
            }
            delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
        }
    }

    public func requestPairing() {
        guard pairState != .paired else { return }
        self.pairState = .requested
        delegate?.deviceConnection(self, didUpdatePairState: .requested)

        let packet = NetworkPacket(
            type: "kdeconnect.pair",
            body: [
                "pair": true,
                "timestamp": Int64(Date().timeIntervalSince1970)
            ]
        )
        send(packet: packet)
    }

    public func acceptPairing() {
        guard pairState == .requestedByPeer else { return }
        let packet = NetworkPacket(type: "kdeconnect.pair", body: ["pair": true])
        send(packet: packet)
        completePairing()
    }

    public func rejectPairing() {
        let packet = NetworkPacket(type: "kdeconnect.pair", body: ["pair": false])
        send(packet: packet)
        self.pairState = .notPaired
        delegate?.deviceConnection(self, didUpdatePairState: .notPaired)
    }

    public func unpair() {
        rejectPairing()
    }

    private func completePairing() {
        guard let info = peerDeviceInfo else { return }
        self.pairState = .paired

        let pairedDevice = PairedDevice(
            deviceId: info.deviceId,
            deviceName: info.deviceName,
            deviceType: info.deviceType,
            certificateFingerprint: peerCertificateFingerprint ?? ""
        )
        TrustStore.shared.add(device: pairedDevice)
        delegate?.deviceConnection(self, didUpdatePairState: .paired)
        print("[DeviceConnection] Pairing successful with \(info.deviceName) (\(info.deviceId))")
    }

    public func send(packet: NetworkPacket) {
        guard let data = try? packet.serialize() else { return }
        writeRaw(data: data)
    }

    private func writeRaw(data: Data) {
        guard let outputStream = outputStream else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            outputStream.write(ptr, maxLength: data.count)
        }
    }
}
