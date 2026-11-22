//
//  TetherTests.swift
//  TetherTests
//

import Testing
import Foundation
@testable import Tether

struct TetherTests {

    @Test func testNetworkPacketSerialization() throws {
        let packet = NetworkPacket(
            type: "kdeconnect.clipboard",
            body: [
                "content": "Hello from Swift!",
                "timestamp": Int64(1234567890)
            ]
        )

        let data = try packet.serialize()
        #expect(data.last == UInt8(ascii: "\n"))

        let decoded = try NetworkPacket.unserialize(from: data)
        #expect(decoded.type == "kdeconnect.clipboard")
        #expect(decoded.string(for: "content") == "Hello from Swift!")
        #expect(decoded.int64(for: "timestamp") == 1234567890)
    }

    /// KDE Connect Android ends a call with `"isCancel": "true"`, a string.
    @Test func testBoolReadsStringsFromAndroid() throws {
        let json = #"{"id":1,"type":"kdeconnect.telephony","body":{"event":"talking","isCancel":"true","a":true,"b":"false","c":"maybe"}}"#
        let packet = try NetworkPacket.unserialize(from: Data(json.utf8))
        #expect(packet.bool(for: "isCancel"))
        #expect(packet.bool(for: "a"))
        #expect(!packet.bool(for: "b", default: true))
        #expect(packet.bool(for: "c", default: true))
        #expect(!packet.bool(for: "missing"))
    }

    /// Values wrapped in AnyCodable inside other containers, as an SMS
    /// request builds its address list, must still reach the wire.
    @Test func testNestedAnyCodableSerializes() throws {
        let packet = NetworkPacket(type: "kdeconnect.sms.request", body: [
            "version": AnyCodable(2),
            "addresses": AnyCodable([["address": AnyCodable("+15550100")]]),
            "messageBody": AnyCodable("test")
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: packet.serialize()) as? [String: Any])
        let body = try #require(json["body"] as? [String: Any])
        let addresses = try #require(body["addresses"] as? [[String: Any]])
        #expect(addresses.first?["address"] as? String == "+15550100")
        #expect(body["messageBody"] as? String == "test")
    }

    @Test func testDeviceInfoPacketConversion() throws {
        let info = DeviceInfo(
            deviceId: "abcdef0123456789abcdef0123456789",
            deviceName: "My Pixel Phone",
            deviceType: .phone,
            protocolVersion: 8,
            tcpPort: 1716
        )

        let discoveryPacket = info.toUdpDiscoveryPacket()
        #expect(discoveryPacket.type == "kdeconnect.identity")
        #expect(discoveryPacket.string(for: "deviceId") == "abcdef0123456789abcdef0123456789")
        #expect(discoveryPacket.int(for: "tcpPort") == 1716)

        let parsedInfo = DeviceInfo.from(packet: discoveryPacket)
        #expect(parsedInfo != nil)
        #expect(parsedInfo?.deviceId == "abcdef0123456789abcdef0123456789")
        #expect(parsedInfo?.deviceName == "My Pixel Phone")
    }

    /// An identity is read from UDP before anything is verified; a port that
    /// doesn't fit 16 bits used to trap when the connection was dialled.
    @Test func testIdentityRejectsUndialablePorts() throws {
        func identity(tcpPort: String?) throws -> DeviceInfo? {
            let port = tcpPort.map { #","tcpPort":\#($0)"# } ?? ""
            let json = #"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"abcdef0123456789abcdef0123456789","deviceName":"Pixel"\#(port)}}"#
            return DeviceInfo.from(packet: try NetworkPacket.unserialize(from: Data(json.utf8)))
        }

        #expect(try identity(tcpPort: "1716")?.tcpPort == 1716)
        #expect(try identity(tcpPort: "65535")?.tcpPort == 65535)
        // No port is fine: the TLS identity doesn't carry one.
        #expect(try #require(try identity(tcpPort: nil)).tcpPort == nil)
        #expect(try identity(tcpPort: "70000") == nil)
        #expect(try identity(tcpPort: "0") == nil)
        #expect(try identity(tcpPort: "-1") == nil)
    }

    @Test func testDeviceIdentity() throws {
        let identity = DeviceIdentity.shared
        #expect(!identity.deviceId.isEmpty)
        #expect(identity.deviceId.count == 32)
        #expect(!identity.certificateFingerprint.isEmpty)
        #expect(identity.certificateFingerprint.contains(":"))
    }

    @Test func testTrustStoreOperations() throws {
        let store = TrustStore.shared
        let testId = "test_device_id_123456789012345678"
        let device = PairedDevice(
            deviceId: testId,
            deviceName: "Test Android",
            deviceType: .phone,
            certificateFingerprint: "AA:BB:CC:DD:EE:FF"
        )

        store.add(device: device)
        #expect(store.isTrusted(deviceId: testId))

        let fetched = store.pairedDevice(for: testId)
        #expect(fetched?.deviceName == "Test Android")

        store.remove(deviceId: testId, reason: "unit test cleanup")
        #expect(!store.isTrusted(deviceId: testId))
    }

    /// The uploader must hand back a port inside the range upstream reserves.
    @Test func testPayloadUploaderBindsInReservedRange() async throws {
        let url = try makeTemporaryPayload(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let uploader = PayloadUploader()
            uploader.start(
                fileURL: url,
                onReady: { offer in continuation.resume(returning: offer.port) },
                onProgress: { _ in },
                onComplete: { _ in }
            )
        }

        #expect(port >= PayloadPort.min)
        #expect(port <= PayloadPort.max)
    }

    /// End-to-end: TLS server streams a file, TLS client reassembles it byte-for-byte.
    /// Sized past one chunk so the framing loop is exercised more than once.
    @Test func testPayloadRoundTripOverLocalhost() async throws {
        let byteCount = 300 * 1024
        let url = try makeTemporaryPayload(bytes: byteCount)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = try Data(contentsOf: url)
        let guardOnce = ResumeGuard()
        let uploader = PayloadUploader()
        var uploaderProgress: [Double] = []

        let received: Data = try await withCheckedThrowingContinuation { continuation in
            uploader.start(
                fileURL: url,
                onReady: { offer in
                    // Both ends use this Mac's identity on localhost, so pinning to
                    // our own fingerprint exercises the verification path.
                    PayloadDownloader.download(
                        host: "127.0.0.1",
                        port: offer.port,
                        size: offer.size,
                        expectedPeerFingerprint: DeviceIdentity.shared.certificateFingerprint
                    ) { result in
                        // The uploader reports its own failures; only one side wins.
                        guard guardOnce.claim() else { return }
                        continuation.resume(with: result.flatMap { fileURL in
                            defer { try? FileManager.default.removeItem(at: fileURL) }
                            return Result { try Data(contentsOf: fileURL) }
                        })
                    }
                },
                onProgress: { uploaderProgress.append($0) },
                onComplete: { result in
                    if case .failure(let error) = result, guardOnce.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            )
        }

        #expect(received.count == byteCount)
        #expect(received == expected)
        #expect(uploaderProgress.count > 1, "expected multiple progress callbacks across chunks")
        #expect(uploaderProgress.last.map { $0 >= 1.0 } == true)
    }

    /// A payload server holding a different certificate than the paired device
    /// must be refused, and nothing may be left on disk.
    @Test func testPayloadDownloadRejectsUnpinnedCertificate() async throws {
        let url = try makeTemporaryPayload(bytes: 4096)
        defer { try? FileManager.default.removeItem(at: url) }

        let uploader = PayloadUploader()
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            uploader.start(
                fileURL: url,
                onReady: { offer in
                    PayloadDownloader.download(
                        host: "127.0.0.1",
                        port: offer.port,
                        size: offer.size,
                        expectedPeerFingerprint: String(repeating: "00:", count: 31) + "00"
                    ) { continuation.resume(returning: $0) }
                },
                onProgress: { _ in },
                onComplete: { _ in }
            )
        }
        uploader.cancel()

        guard case .failure(let error) = result else {
            Issue.record("download should have been refused")
            return
        }
        guard case PayloadError.certificateMismatch = error else {
            Issue.record("expected certificateMismatch, got \(error)")
            return
        }
    }

    @Test func testFingerprintComparison() {
        #expect(SocketTLS.fingerprintsMatch("ab:cd", "AB:CD"))
        #expect(!SocketTLS.fingerprintsMatch("ab:cd", "ab:ce"))
        #expect(!SocketTLS.fingerprintsMatch("", ""))
        #expect(!SocketTLS.fingerprintsMatch(nil, "ab:cd"))
    }

    /// Peer-supplied file names must never leave the target directory.
    @Test func testSafeFilenameStripsTraversal() {
        #expect(SafeFilename.sanitize("../../Library/LaunchAgents/evil.plist") == "evil.plist")
        #expect(SafeFilename.sanitize("..\\..\\x.txt") == "x.txt")
        #expect(SafeFilename.sanitize("/etc/passwd") == "passwd")
        #expect(SafeFilename.sanitize("..") == "ReceivedFile")
        #expect(SafeFilename.sanitize(".hidden") == "hidden")
        #expect(SafeFilename.sanitize(nil) == "ReceivedFile")
        #expect(SafeFilename.sanitize("photo.jpg") == "photo.jpg")

        let dir = FileManager.default.temporaryDirectory
        let target = SafeFilename.uniqueURL(in: dir, for: "../../escape.txt")
        #expect(target.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    /// Only the user's own, online phones get our identity: shared-in machines,
    /// desktops and offline devices are skipped, and IPv6 addresses ignored.
    @Test func testTailscalePeerFiltering() throws {
        let json = """
        {
          "BackendState": "Running",
          "Self": { "UserID": 7, "TailscaleIPs": ["100.101.42.7", "fd7a::1"] },
          "Peer": {
            "a": { "HostName": "pixel", "OS": "android", "Online": true, "UserID": 7, "TailscaleIPs": ["fd7a::2", "100.88.17.53"] },
            "b": { "HostName": "friends-phone", "OS": "android", "Online": true, "UserID": 99, "TailscaleIPs": ["100.64.0.9"] },
            "c": { "HostName": "server", "OS": "linux", "Online": true, "UserID": 7, "TailscaleIPs": ["100.127.50.25"] },
            "d": { "HostName": "old-phone", "OS": "android", "Online": false, "UserID": 7, "TailscaleIPs": ["100.64.0.10"] },
            "e": { "HostName": "ipad", "OS": "iOS", "Online": true, "UserID": 7, "TailscaleIPs": ["100.64.0.11"] }
          }
        }
        """
        let status = TailscaleDiscovery.parse(Data(json.utf8))
        guard case .running(let selfIP, let phones) = status else {
            Issue.record("expected running, got \(status)")
            return
        }
        #expect(selfIP == "100.101.42.7")
        #expect(phones.map(\.ip) == ["100.64.0.11", "100.88.17.53"])

        let stopped = TailscaleDiscovery.parse(Data(#"{"BackendState":"Stopped"}"#.utf8))
        #expect(stopped == .notRunning)
    }

    /// A packet type must be advertised in the direction it actually travels. The
    /// peer refuses to send a type missing from our incoming set, and ignores what
    /// we send if it is missing from our outgoing set.
    @Test func testCapabilityDirections() throws {
        let incoming = DeviceInfo.defaultIncomingCapabilities
        let outgoing = DeviceInfo.defaultOutgoingCapabilities

        for type in [
            "kdeconnect.mpris",
            "kdeconnect.systemvolume",
            "kdeconnect.lock",
            "kdeconnect.connectivity_report",
            "kdeconnect.telephony",
            "kdeconnect.share.request",
            "kdeconnect.share.request.update",
            "kdeconnect.mousepad.request",
            "kdeconnect.presenter",
            "kdeconnect.sms.messages",
            "kdeconnect.sms.attachment_file",
            "kdeconnect.runcommand.request",
            // Ring this Mac: the same packet type rings in either direction.
            "kdeconnect.findmyphone.request",
            // The phone's volume panel controls this Mac's volume too.
            "kdeconnect.systemvolume.request",
            // And its Multimedia control drives this Mac as a player.
            "kdeconnect.mpris.request"
        ] {
            #expect(incoming.contains(type), "\(type) must be receivable")
        }

        for type in [
            "kdeconnect.mpris.request",
            "kdeconnect.findmyphone.request",
            "kdeconnect.systemvolume.request",
            "kdeconnect.lock.request",
            "kdeconnect.share.request",
            "kdeconnect.mousepad.keyboardstate",
            "kdeconnect.mousepad.echo",
            "kdeconnect.sms.request",
            "kdeconnect.sms.request_conversations",
            "kdeconnect.sms.request_conversation",
            "kdeconnect.sms.request_attachment",
            "kdeconnect.runcommand",
            "kdeconnect.runcommand.output"
        ] {
            #expect(outgoing.contains(type), "\(type) must be sendable")
        }

        // Request/response pairs must not be conflated.
        #expect(!outgoing.contains("kdeconnect.telephony"))
        #expect(!incoming.contains("kdeconnect.mousepad.keyboardstate"))
        #expect(!outgoing.contains("kdeconnect.mousepad.request"))
        #expect(!outgoing.contains("kdeconnect.sms.messages"))
        #expect(!incoming.contains("kdeconnect.sms.request"))
    }

    @Test func testSMSMessageParsing() throws {
        let smsJSON = """
        {
            "id": 100,
            "type": "kdeconnect.sms.messages",
            "body": {
                "version": 2,
                "messages": [
                    {
                        "event": 1,
                        "body": "Hello from Android!",
                        "addresses": [{"address": "+15551234567"}],
                        "date": 1690000000000,
                        "type": 1,
                        "thread_id": 42,
                        "read": true,
                        "attachments": [
                            {
                                "part_id": 1,
                                "mime_type": "image/jpeg",
                                "unique_identifier": "img_001.jpg"
                            }
                        ]
                    }
                ]
            }
        }
        """
        let packet = try NetworkPacket.unserialize(from: Data(smsJSON.utf8))
        let messages = packet.objectArray(for: "messages")
        #expect(messages.count == 1)

        let parsed = SMSMessage.from(dictionary: messages[0])
        #expect(parsed != nil)
        #expect(parsed?.body == "Hello from Android!")
        #expect(parsed?.addresses == ["+15551234567"])
        #expect(parsed?.threadId == 42)
        #expect(parsed?.type == 1)
        #expect(parsed?.isOutgoing == false)
        #expect(parsed?.read == true)
        #expect(parsed?.attachments.count == 1)
        #expect(parsed?.attachments[0].uniqueIdentifier == "img_001.jpg")
    }

    @Test func testRemoteCommandExecution() async throws {
        // Its own settings: the tests run inside the app, and the standard
        // defaults hold the commands people actually use.
        let suite = "TetherTests.RunCommand.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let plugin = RunCommandPlugin(defaults: defaults)
        let cmd = RemoteCommand(id: "test_echo", name: "Echo Test", command: "echo 'Antigravity Test'")
        plugin.addCommand(cmd)

        plugin.startCommand(key: "test_echo", connection: nil)

        // Give process a moment to execute
        try await Task.sleep(nanoseconds: 300_000_000)

        let logs = plugin.commandLogs["test_echo"] ?? []
        #expect(logs.contains { $0.contains("Antigravity Test") })
        #expect(logs.contains { $0.contains("Finished with exit code 0") })
    }

    @Test func testDoublePacketAccessor() throws {
        let packet = NetworkPacket(
            type: "kdeconnect.mousepad.request",
            body: [
                "dx": AnyCodable(12.5),
                "dy": AnyCodable(-4.25),
                "singleclick": AnyCodable(true)
            ]
        )
        #expect(packet.double(for: "dx") == 12.5)
        #expect(packet.double(for: "dy") == -4.25)
        #expect(packet.bool(for: "singleclick") == true)
        #expect(packet.has("dx") == true)
        #expect(packet.has("nonexistent") == false)
    }

    /// Nested JSON arrives shallowly typed through `AnyCodable`, so the object
    /// accessors have to unwrap it by hand.
    @Test func testNestedObjectAccessors() throws {
        let json = """
        {"id":1,"type":"kdeconnect.systemvolume","body":{"sinkList":[\
        {"name":"Music","description":"Built-in","muted":false,"volume":42,"maxVolume":100,"enabled":true}\
        ]}}
        """
        let packet = try NetworkPacket.unserialize(from: Data(json.utf8))

        let sinks = packet.objectArray(for: "sinkList")
        #expect(sinks.count == 1)
        #expect(sinks.first?["name"] as? String == "Music")
        #expect(sinks.first?["volume"] as? Int == 42)
        #expect(sinks.first?["enabled"] as? Bool == true)

        let strengthsJSON = """
        {"id":2,"type":"kdeconnect.connectivity_report","body":{"signalStrengths":{\
        "0":{"networkType":"LTE","signalStrength":3}\
        }}}
        """
        let strengthsPacket = try NetworkPacket.unserialize(from: Data(strengthsJSON.utf8))
        let strengths = strengthsPacket.object(for: "signalStrengths")
        #expect(strengths?.count == 1)

        let entry = strengths?["0"] as? [String: Any]
        #expect(entry?["networkType"] as? String == "LTE")
        #expect(entry?["signalStrength"] as? Int == 3)
    }

    // MARK: - Helpers

    private func makeTemporaryPayload(bytes: Int) throws -> URL {
        var payload = Data(count: bytes)
        payload.withUnsafeMutableBytes { buffer in
            for index in 0..<bytes {
                buffer[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-payload-test-\(UUID().uuidString).bin")
        try payload.write(to: url)
        return url
    }
}

/// Lets only the first of several racing callbacks resolve a continuation.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !isClaimed else { return false }
            isClaimed = true
            return true
        }
    }
}
