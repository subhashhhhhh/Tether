//
//  KDEConnectTests.swift
//  KDEConnectTests
//

import Testing
import Foundation
@testable import KDEConnect

struct KDEConnectTests {

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
}
