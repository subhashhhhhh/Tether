//
//  SSHConnection.swift
//  Tether
//
//  A minimal SSH-2 client, enough for one SFTP session with KDE Connect's
//  SFTP server (Apache MINA SSHD on Android):
//
//  - key exchange: curve25519-sha256 or ecdh-sha2-nistp256, with strict key
//    exchange (the Terrapin mitigation) when the server supports it
//  - host keys: ssh-ed25519, ecdsa-sha2-nistp256, rsa-sha2-256/512
//  - encryption: aes128-gcm / aes256-gcm (OpenSSH's GCM, RFC 5647 framing)
//  - password authentication, one session channel, server-initiated rekeying
//
//  Everything uses CryptoKit and Security; there are no third-party libraries.
//

import CryptoKit
import Foundation
import Security

nonisolated enum SSHError: LocalizedError, Equatable {
    case protocolError(String)
    case unsupported(String)
    case hostKeyMismatch
    case badHostKeySignature
    case authenticationFailed
    case disconnected(String)
    case channelFailed(String)

    var errorDescription: String? {
        switch self {
        case .protocolError(let detail): "SSH protocol error: \(detail)"
        case .unsupported(let what): "The phone's file server uses \(what), which Tether doesn't support."
        case .hostKeyMismatch: "The phone's file server identified itself with a different key than before."
        case .badHostKeySignature: "The phone's file server failed to prove its identity."
        case .authenticationFailed: "The phone's file server refused the login."
        case .disconnected(let reason): "The file connection closed: \(reason)"
        case .channelFailed(let reason): "Couldn't start the file session: \(reason)"
        }
    }
}

/// The server's host key, as presented during key exchange.
nonisolated struct SSHHostKey: Sendable {
    let algorithm: String
    let blob: Data

    /// "SHA256:…" as OpenSSH prints it.
    var fingerprint: String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

private nonisolated enum Message {
    static let disconnect: UInt8 = 1
    static let ignore: UInt8 = 2
    static let unimplemented: UInt8 = 3
    static let debug: UInt8 = 4
    static let serviceRequest: UInt8 = 5
    static let serviceAccept: UInt8 = 6
    static let extInfo: UInt8 = 7
    static let kexInit: UInt8 = 20
    static let newKeys: UInt8 = 21
    static let kexECDHInit: UInt8 = 30
    static let kexECDHReply: UInt8 = 31
    static let userauthRequest: UInt8 = 50
    static let userauthFailure: UInt8 = 51
    static let userauthSuccess: UInt8 = 52
    static let userauthBanner: UInt8 = 53
    static let globalRequest: UInt8 = 80
    static let requestFailure: UInt8 = 82
    static let channelOpen: UInt8 = 90
    static let channelOpenConfirmation: UInt8 = 91
    static let channelOpenFailure: UInt8 = 92
    static let channelWindowAdjust: UInt8 = 93
    static let channelData: UInt8 = 94
    static let channelExtendedData: UInt8 = 95
    static let channelEOF: UInt8 = 96
    static let channelClose: UInt8 = 97
    static let channelRequest: UInt8 = 98
    static let channelSuccess: UInt8 = 99
    static let channelFailure: UInt8 = 100
}

/// One direction's AES-GCM state. The last 8 bytes of the nonce count packets.
private nonisolated struct GCMState {
    let key: SymmetricKey
    var nonce: [UInt8]

    mutating func advance() {
        var index = 11
        while index >= 4 {
            nonce[index] &+= 1
            if nonce[index] != 0 { break }
            index -= 1
        }
    }
}

actor SSHConnection {
    static let clientVersion = "SSH-2.0-Tether_1.6"

    private let socket: SSHSocket
    private let checkHostKey: @Sendable (SSHHostKey) -> Bool

    private var serverVersion = ""
    private var sessionID: Data?
    private var outgoing: GCMState?
    private var incoming: GCMState?
    private var outgoingSequence: UInt32 = 0
    private var incomingSequence: UInt32 = 0
    private var strictKex = false

    // Sending pauses while keys are being renegotiated.
    private var rekeying = false
    private var rekeyWaiters: [CheckedContinuation<Void, Never>] = []

    // The one session channel.
    private let localChannel: UInt32 = 0
    private var remoteChannel: UInt32 = 0
    private var remoteWindow: UInt64 = 0
    private var remoteMaxPacket = 32768
    private var windowWaiters: [CheckedContinuation<Void, Error>] = []
    private var writeInProgress = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private let localWindowSize: UInt32 = 8 << 20
    private var localWindowConsumed: UInt32 = 0
    private var channelData: AsyncThrowingStream<Data, Error>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var closedError: Error?

    init(host: String, port: UInt16, checkHostKey: @escaping @Sendable (SSHHostKey) -> Bool) {
        socket = SSHSocket(host: host, port: port)
        self.checkHostKey = checkHostKey
    }

    // MARK: - Public

    /// Connects, verifies the host key, logs in, and opens the SFTP subsystem.
    /// Returns the stream of bytes the server sends on that channel.
    func openSFTP(user: String, password: String) async throws -> AsyncThrowingStream<Data, Error> {
        try await socket.connect()
        try await socket.send(Data((Self.clientVersion + "\r\n").utf8))
        repeat {
            serverVersion = try await socket.receiveLine()
        } while !serverVersion.hasPrefix("SSH-")
        guard serverVersion.hasPrefix("SSH-2.0-") || serverVersion.hasPrefix("SSH-1.99-") else {
            throw SSHError.unsupported("protocol \(serverVersion)")
        }

        try await keyExchange(serverKexInit: nil)
        try await authenticate(user: user, password: password)
        try await openSession()

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            self.channelData = continuation
        }
        readerTask = Task { await self.readLoop() }
        return stream
    }

    /// Sends bytes on the session channel, respecting the server's window.
    /// Writes are serialized: a message split across several channel packets
    /// must not interleave with another write's packets.
    func write(_ data: Data) async throws {
        while writeInProgress {
            await withCheckedContinuation { writeWaiters.append($0) }
        }
        writeInProgress = true
        defer {
            writeInProgress = false
            if !writeWaiters.isEmpty { writeWaiters.removeFirst().resume() }
        }

        var offset = data.startIndex
        while offset < data.endIndex {
            if let closedError { throw closedError }
            while remoteWindow == 0 {
                try await withCheckedThrowingContinuation { windowWaiters.append($0) }
                if let closedError { throw closedError }
            }
            let count = min(data.endIndex - offset, remoteMaxPacket - 64, Int(min(remoteWindow, UInt64(Int.max))))
            remoteWindow -= UInt64(count) // reserve before suspending
            var message = SSHWriter()
            message.byte(Message.channelData)
            message.uint32(remoteChannel)
            message.string(data[offset..<offset + count])
            try await send(message.data)
            offset += count
        }
    }

    func close() {
        fail(with: SSHError.disconnected("closed"))
        socket.close()
    }

    // MARK: - Reading

    private func readLoop() async {
        do {
            while true {
                let payload = try await readPacket()
                try await handleAfterSetup(payload)
            }
        } catch {
            fail(with: error)
        }
    }

    private func handleAfterSetup(_ payload: Data) async throws {
        var reader = SSHReader(payload)
        let type = try reader.byte()
        switch type {
        case Message.channelData:
            _ = try reader.uint32()
            let data = try reader.string()
            channelData?.yield(data)
            localWindowConsumed += UInt32(data.count)
            if localWindowConsumed >= localWindowSize / 2 {
                var adjust = SSHWriter()
                adjust.byte(Message.channelWindowAdjust)
                adjust.uint32(remoteChannel)
                adjust.uint32(localWindowConsumed)
                localWindowConsumed = 0
                try await send(adjust.data)
            }
        case Message.channelWindowAdjust:
            _ = try reader.uint32()
            remoteWindow += UInt64(try reader.uint32())
            let waiters = windowWaiters
            windowWaiters.removeAll()
            waiters.forEach { $0.resume() }
        case Message.channelExtendedData:
            break // stderr of the subsystem; nothing to do with it
        case Message.channelEOF, Message.channelClose:
            throw SSHError.disconnected("the phone closed the file session")
        case Message.channelRequest:
            _ = try reader.uint32()
            _ = try reader.utf8()
            if try reader.bool() {
                var reply = SSHWriter()
                reply.byte(Message.channelFailure)
                reply.uint32(remoteChannel)
                try await send(reply.data)
            }
        case Message.globalRequest:
            _ = try reader.utf8()
            if try reader.bool() { try await send(Data([Message.requestFailure])) }
        case Message.kexInit:
            try await keyExchange(serverKexInit: payload)
        case Message.disconnect:
            _ = try? reader.uint32()
            throw SSHError.disconnected((try? reader.utf8()) ?? "the phone ended the session")
        default:
            break // IGNORE, DEBUG, UNIMPLEMENTED, EXT_INFO, channel success/failure
        }
    }

    /// The next packet that isn't IGNORE or DEBUG, during setup.
    private func nextSetupPacket() async throws -> Data {
        while true {
            let payload = try await readPacket()
            switch payload.first {
            case Message.ignore, Message.debug, Message.unimplemented, Message.extInfo:
                continue
            case Message.disconnect:
                var reader = SSHReader(payload)
                _ = try reader.byte()
                _ = try? reader.uint32()
                throw SSHError.disconnected((try? reader.utf8()) ?? "the phone ended the session")
            default:
                return payload
            }
        }
    }

    // MARK: - Packets

    private func readPacket() async throws -> Data {
        let payload: Data
        if var state = incoming {
            let lengthBytes = try await socket.receive(exactly: 4)
            var lengthReader = SSHReader(lengthBytes)
            let length = Int(try lengthReader.uint32())
            guard length >= 16, length <= 256 * 1024, length % 16 == 0 else {
                throw SSHError.protocolError("bad packet length \(length)")
            }
            let body = try await socket.receive(exactly: length + 16)
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: state.nonce),
                ciphertext: body.prefix(length),
                tag: body.suffix(16)
            )
            let plain: Data
            do {
                plain = try AES.GCM.open(box, using: state.key, authenticating: lengthBytes)
            } catch {
                throw SSHError.protocolError("packet failed authentication")
            }
            state.advance()
            incoming = state
            payload = try Self.unpad(plain)
        } else {
            let lengthBytes = try await socket.receive(exactly: 4)
            var lengthReader = SSHReader(lengthBytes)
            let length = Int(try lengthReader.uint32())
            guard length >= 5, length <= 256 * 1024 else {
                throw SSHError.protocolError("bad packet length \(length)")
            }
            payload = try Self.unpad(try await socket.receive(exactly: length))
        }
        incomingSequence &+= 1
        return payload
    }

    private static func unpad(_ plain: Data) throws -> Data {
        guard let padding = plain.first.map(Int.init), padding >= 4, padding < plain.count else {
            throw SSHError.protocolError("bad padding")
        }
        return Data(plain.dropFirst().dropLast(padding))
    }

    /// Sends a packet, waiting out a key exchange the server started.
    private func send(_ payload: Data) async throws {
        while rekeying, !Self.isKexMessage(payload) {
            await withCheckedContinuation { rekeyWaiters.append($0) }
        }
        try await sendNow(payload)
    }

    private static func isKexMessage(_ payload: Data) -> Bool {
        guard let type = payload.first else { return false }
        return (1...4).contains(type) || (20...49).contains(type)
    }

    private func sendNow(_ payload: Data) async throws {
        if let closedError { throw closedError }
        let blockSize = outgoing == nil ? 8 : 16
        // Length field counts padding-length byte + payload + padding; with GCM
        // the length field itself is excluded from the block alignment.
        let unaligned = (outgoing == nil ? 5 : 1) + payload.count
        var padding = blockSize - unaligned % blockSize
        if padding < 4 { padding += blockSize }

        var plain = Data([UInt8(padding)])
        plain.append(payload)
        var random = [UInt8](repeating: 0, count: padding)
        _ = SecRandomCopyBytes(kSecRandomDefault, padding, &random)
        plain.append(contentsOf: random)

        let lengthBytes = UInt32(plain.count).bigEndianData
        var packet = lengthBytes
        if var state = outgoing {
            let box = try AES.GCM.seal(plain, using: state.key, nonce: AES.GCM.Nonce(data: state.nonce), authenticating: lengthBytes)
            packet.append(box.ciphertext)
            packet.append(box.tag)
            state.advance()
            outgoing = state
        } else {
            packet.append(plain)
        }
        outgoingSequence &+= 1
        try await socket.send(packet)
    }

    // MARK: - Key exchange

    private static let kexAlgorithms = ["curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256"]
    private static let hostKeyAlgorithms = ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256"]
    private static let ciphers = ["aes128-gcm@openssh.com", "aes256-gcm@openssh.com"]
    private static let macs = ["hmac-sha2-256", "hmac-sha2-512"] // negotiated but unused with GCM

    /// Runs a key exchange. `serverKexInit` is set when the server started it
    /// (a rekey); otherwise this is the first exchange and we speak first.
    private func keyExchange(serverKexInit: Data?) async throws {
        let isFirst = sessionID == nil
        rekeying = true
        defer {
            rekeying = false
            let waiters = rekeyWaiters
            rekeyWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        var cookie = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &cookie)
        var clientKexInit = SSHWriter()
        clientKexInit.byte(Message.kexInit)
        clientKexInit.raw(Data(cookie))
        clientKexInit.nameList(Self.kexAlgorithms + (isFirst ? ["kex-strict-c-v00@openssh.com"] : []))
        clientKexInit.nameList(Self.hostKeyAlgorithms)
        clientKexInit.nameList(Self.ciphers)
        clientKexInit.nameList(Self.ciphers)
        clientKexInit.nameList(Self.macs)
        clientKexInit.nameList(Self.macs)
        clientKexInit.nameList(["none"])
        clientKexInit.nameList(["none"])
        clientKexInit.nameList([])
        clientKexInit.nameList([])
        clientKexInit.bool(false)
        clientKexInit.uint32(0)
        try await sendNow(clientKexInit.data)

        let serverInit: Data
        if let serverKexInit {
            serverInit = serverKexInit
        } else {
            serverInit = try await readPacket()
            guard serverInit.first == Message.kexInit else {
                throw SSHError.protocolError("expected KEXINIT, got \(serverInit.first ?? 0)")
            }
        }

        var reader = SSHReader(serverInit)
        _ = try reader.byte()
        _ = try reader.bytes(16)
        let serverKex = try reader.nameList()
        let serverHostKeys = try reader.nameList()
        let serverCiphersCS = try reader.nameList()
        let serverCiphersSC = try reader.nameList()

        if isFirst {
            strictKex = serverKex.contains("kex-strict-s-v00@openssh.com")
            // Strict key exchange requires KEXINIT to be the very first packet.
            if strictKex, incomingSequence != 1 { throw SSHError.protocolError("unexpected packet before KEXINIT") }
        }

        guard let kex = Self.kexAlgorithms.first(where: serverKex.contains) else { throw SSHError.unsupported("key exchange \(serverKex)") }
        guard Self.hostKeyAlgorithms.contains(where: serverHostKeys.contains) else { throw SSHError.unsupported("host key \(serverHostKeys)") }
        guard let cipherCS = Self.ciphers.first(where: serverCiphersCS.contains),
              let cipherSC = Self.ciphers.first(where: serverCiphersSC.contains) else {
            throw SSHError.unsupported("encryption \(serverCiphersCS)")
        }

        // ECDH: our ephemeral public key out, the server's back.
        let clientPublic: Data
        let agree: (Data) throws -> Data
        if kex.hasPrefix("curve25519") {
            let key = Curve25519.KeyAgreement.PrivateKey()
            clientPublic = key.publicKey.rawRepresentation
            agree = { peer in
                let secret = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
                return secret.withUnsafeBytes { Data($0) }
            }
        } else {
            let key = P256.KeyAgreement.PrivateKey()
            clientPublic = key.publicKey.x963Representation
            agree = { peer in
                let secret = try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer))
                return secret.withUnsafeBytes { Data($0) }
            }
        }

        var ecdhInit = SSHWriter()
        ecdhInit.byte(Message.kexECDHInit)
        ecdhInit.string(clientPublic)
        try await sendNow(ecdhInit.data)

        let reply = try await readPacket()
        guard reply.first == Message.kexECDHReply else {
            throw SSHError.protocolError("expected ECDH reply, got \(reply.first ?? 0)")
        }
        var replyReader = SSHReader(reply)
        _ = try replyReader.byte()
        let hostKeyBlob = try replyReader.string()
        let serverPublic = try replyReader.string()
        let signature = try replyReader.string()

        let sharedSecret = try agree(serverPublic)
        var encodedSecret = SSHWriter()
        encodedSecret.mpint(unsigned: sharedSecret)

        var exchange = SSHWriter()
        exchange.string(Self.clientVersion)
        exchange.string(serverVersion)
        exchange.string(clientKexInit.data)
        exchange.string(serverInit)
        exchange.string(hostKeyBlob)
        exchange.string(clientPublic)
        exchange.string(serverPublic)
        exchange.raw(encodedSecret.data)
        let hash = Data(SHA256.hash(data: exchange.data))

        let hostKey = try Self.verifyHostKey(blob: hostKeyBlob, signature: signature, over: hash)
        guard checkHostKey(hostKey) else { throw SSHError.hostKeyMismatch }

        let session = sessionID ?? hash
        sessionID = session

        func derive(_ letter: Character, _ length: Int) -> Data {
            var material = Data(SHA256.hash(data: encodedSecret.data + hash + Data([UInt8(letter.asciiValue!)]) + session))
            while material.count < length {
                material += Data(SHA256.hash(data: encodedSecret.data + hash + material))
            }
            return material.prefix(length)
        }
        func keyLength(_ cipher: String) -> Int { cipher.hasPrefix("aes256") ? 32 : 16 }

        let nextOutgoing = GCMState(key: SymmetricKey(data: derive("C", keyLength(cipherCS))), nonce: Array(derive("A", 12)))
        let nextIncoming = GCMState(key: SymmetricKey(data: derive("D", keyLength(cipherSC))), nonce: Array(derive("B", 12)))

        try await sendNow(Data([Message.newKeys]))
        outgoing = nextOutgoing
        if strictKex { outgoingSequence = 0 }

        let newKeys = try await readPacket()
        guard newKeys.first == Message.newKeys else {
            throw SSHError.protocolError("expected NEWKEYS, got \(newKeys.first ?? 0)")
        }
        incoming = nextIncoming
        if strictKex { incomingSequence = 0 }
    }

    /// Checks the server signed the exchange hash with the key it presented.
    private static func verifyHostKey(blob: Data, signature: Data, over hash: Data) throws -> SSHHostKey {
        var keyReader = SSHReader(blob)
        let keyType = try keyReader.utf8()
        var signatureReader = SSHReader(signature)
        let signatureType = try signatureReader.utf8()
        let signatureBytes = try signatureReader.string()

        let valid: Bool
        switch keyType {
        case "ssh-ed25519":
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: try keyReader.string())
            valid = signatureType == "ssh-ed25519" && key.isValidSignature(signatureBytes, for: hash)
        case "ecdsa-sha2-nistp256":
            _ = try keyReader.utf8() // curve name
            let key = try P256.Signing.PublicKey(x963Representation: try keyReader.string())
            var parts = SSHReader(signatureBytes)
            let r = try parts.mpint(), s = try parts.mpint()
            guard r.count <= 32, s.count <= 32 else { throw SSHError.badHostKeySignature }
            let raw = Data(repeating: 0, count: 32 - r.count) + r + Data(repeating: 0, count: 32 - s.count) + s
            let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: raw)
            valid = signatureType == "ecdsa-sha2-nistp256" && key.isValidSignature(ecdsa, for: hash)
        case "ssh-rsa":
            let exponent = try keyReader.mpint()
            let modulus = try keyReader.mpint()
            let algorithm: SecKeyAlgorithm
            switch signatureType {
            case "rsa-sha2-256": algorithm = .rsaSignatureMessagePKCS1v15SHA256
            case "rsa-sha2-512": algorithm = .rsaSignatureMessagePKCS1v15SHA512
            default: throw SSHError.unsupported("signature \(signatureType)")
            }
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
            guard let key = SecKeyCreateWithData(DER.rsaPublicKey(modulus: modulus, exponent: exponent) as CFData, attributes as CFDictionary, nil) else {
                throw SSHError.badHostKeySignature
            }
            valid = SecKeyVerifySignature(key, algorithm, hash as CFData, signatureBytes as CFData, nil)
        default:
            throw SSHError.unsupported("host key \(keyType)")
        }
        guard valid else { throw SSHError.badHostKeySignature }
        return SSHHostKey(algorithm: keyType, blob: blob)
    }

    // MARK: - Authentication and channel

    private func authenticate(user: String, password: String) async throws {
        var request = SSHWriter()
        request.byte(Message.serviceRequest)
        request.string("ssh-userauth")
        try await send(request.data)
        guard try await nextSetupPacket().first == Message.serviceAccept else {
            throw SSHError.protocolError("ssh-userauth not accepted")
        }

        var auth = SSHWriter()
        auth.byte(Message.userauthRequest)
        auth.string(user)
        auth.string("ssh-connection")
        auth.string("password")
        auth.bool(false)
        auth.string(password)
        try await send(auth.data)

        while true {
            switch try await nextSetupPacket().first {
            case Message.userauthSuccess: return
            case Message.userauthBanner: continue
            case Message.userauthFailure: throw SSHError.authenticationFailed
            default: throw SSHError.protocolError("unexpected reply to login")
            }
        }
    }

    private func openSession() async throws {
        var open = SSHWriter()
        open.byte(Message.channelOpen)
        open.string("session")
        open.uint32(localChannel)
        open.uint32(localWindowSize)
        open.uint32(256 * 1024)
        try await send(open.data)

        let reply = try await nextSetupPacket()
        var reader = SSHReader(reply)
        switch try reader.byte() {
        case Message.channelOpenConfirmation:
            _ = try reader.uint32()
            remoteChannel = try reader.uint32()
            remoteWindow = UInt64(try reader.uint32())
            remoteMaxPacket = max(1024, min(Int(try reader.uint32()), 256 * 1024))
        case Message.channelOpenFailure:
            _ = try reader.uint32()
            _ = try reader.uint32()
            throw SSHError.channelFailed((try? reader.utf8()) ?? "refused")
        default:
            throw SSHError.protocolError("unexpected reply to channel open")
        }

        var subsystem = SSHWriter()
        subsystem.byte(Message.channelRequest)
        subsystem.uint32(remoteChannel)
        subsystem.string("subsystem")
        subsystem.bool(true)
        subsystem.string("sftp")
        try await send(subsystem.data)

        while true {
            let packet = try await nextSetupPacket()
            var packetReader = SSHReader(packet)
            switch try packetReader.byte() {
            case Message.channelSuccess:
                return
            case Message.channelFailure:
                throw SSHError.channelFailed("the phone has no SFTP subsystem")
            case Message.channelWindowAdjust:
                _ = try packetReader.uint32()
                remoteWindow += UInt64(try packetReader.uint32())
            case Message.globalRequest:
                _ = try packetReader.utf8()
                if try packetReader.bool() { try await send(Data([Message.requestFailure])) }
            default:
                continue
            }
        }
    }

    private func fail(with error: Error) {
        guard closedError == nil else { return }
        closedError = error
        channelData?.finish(throwing: error)
        channelData = nil
        let waiters = windowWaiters
        windowWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
        let writers = writeWaiters
        writeWaiters.removeAll()
        writers.forEach { $0.resume() }
        socket.close()
    }
}

/// Just enough DER to hand an SSH RSA key to the Security framework.
private nonisolated enum DER {
    static func rsaPublicKey(modulus: Data, exponent: Data) -> Data {
        sequence(integer(modulus) + integer(exponent))
    }

    private static func integer(_ magnitude: Data) -> Data {
        var bytes = Data(magnitude.drop { $0 == 0 })
        if (bytes.first ?? 0x80) & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + length(bytes.count) + bytes
    }

    private static func sequence(_ content: Data) -> Data {
        Data([0x30]) + length(content.count) + content
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
