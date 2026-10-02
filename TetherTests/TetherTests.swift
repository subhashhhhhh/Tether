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

        store.remove(deviceId: testId)
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
                    PayloadDownloader.download(
                        host: "127.0.0.1",
                        port: offer.port,
                        size: offer.size
                    ) { result in
                        // The uploader reports its own failures; only one side wins.
                        guard guardOnce.claim() else { return }
                        continuation.resume(with: result)
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
            "kdeconnect.runcommand.request"
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
        #expect(!incoming.contains("kdeconnect.mpris.request"))
        #expect(!incoming.contains("kdeconnect.findmyphone.request"))
        #expect(!outgoing.contains("kdeconnect.mpris"))
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
        let plugin = RunCommandPlugin()
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
