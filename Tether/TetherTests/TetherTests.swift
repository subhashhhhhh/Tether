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
