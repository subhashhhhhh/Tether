//
//  NotificationParsingTests.swift
//  TetherTests
//

import Darwin
import Foundation
import Testing
@testable import Tether

struct NotificationParsingTests {
    private func item(id: String, appName: String = "WhatsApp") -> PhoneNotification {
        PhoneNotification(id: id, deviceId: "d", appName: appName, title: "", text: "", date: .now,
                          replyId: nil, isDismissable: true)
    }

    @Test func readsThePackageFromAnAndroidKey() {
        #expect(item(id: "0|com.whatsapp|12|tag|10123").packageName == "com.whatsapp")
        #expect(item(id: "0|com.whatsapp|12|tag|10123").glyphKey == "com.whatsapp")
        #expect(item(id: "opaque-id").packageName == nil)
        #expect(item(id: "opaque-id").glyphKey == "WhatsApp")
    }

    @Test func namesTheSenderWhereItChanges() {
        let lines: [PhoneNotification.ConversationLine] = [
            .init(sender: "Alex", content: "Hi"),
            .init(sender: "Alex", content: "Are you there?"),
            .init(sender: "Sam", content: "Yes"),
        ]
        #expect(NotificationPlugin.plainText(of: lines, title: "Alex") == "Hi\nAre you there?\nSam: Yes")
    }

    @Test func spotsAndroidsHiddenText() {
        #expect(NotificationPlugin.isRedacted("Sensitive notification content hidden"))
        #expect(NotificationPlugin.isRedacted("  sensitive notification content hidden\n"))
        #expect(!NotificationPlugin.isRedacted("Your code is 123456"))
    }

    @Test func findsACodeInAButton() {
        #expect(OneTimeCode.find(inAction: ["Mark as read", "Copy \u{2063}4\u{2063}8\u{2063}2\u{2063}9\u{2063}1\u{2063}3"]) == "482913")
        #expect(OneTimeCode.find(inAction: ["Copy 739104"]) == "739104")
        #expect(OneTimeCode.find(inAction: ["Reply", "Mute"]) == nil)
    }
}

struct IdentityValidationTests {
    private func identity(id: String, name: String = "Pixel 9", version: Int = 8) -> DeviceInfo? {
        DeviceInfo.from(packet: NetworkPacket(type: "kdeconnect.identity", body: [
            "deviceId": id, "deviceName": name, "protocolVersion": version,
        ]))
    }

    @Test func acceptsKDEStyleIDs() {
        #expect(identity(id: "53ac2416aa7a49efbfaaf0783ed6cf89") != nil)
        #expect(identity(id: "_7c4b1a2e_3f0d_4e2b_9a1c_8d6e5f4a3b2c_") != nil)
    }

    @Test func rejectsMalformedIdentities() {
        #expect(identity(id: "short") == nil)
        #expect(identity(id: "53ac2416aa7a49efbfaaf0783ed6cf89/../x") == nil)
        #expect(identity(id: "53ac2416aa7a49efbfaaf0783ed6cf89", version: 7) == nil)
    }

    @Test func cleansNames() {
        #expect(identity(id: "53ac2416aa7a49efbfaaf0783ed6cf89", name: "Harsh's <Pixel>!")?.deviceName == "Harshs Pixel")
        #expect(identity(id: "53ac2416aa7a49efbfaaf0783ed6cf89", name: String(repeating: "a", count: 40))?.deviceName.count == 32)
        #expect(identity(id: "53ac2416aa7a49efbfaaf0783ed6cf89", name: "!!!")?.deviceName == "Unknown Device")
    }
}

struct SMSMergeTests {
    private func message(_ body: String, id: Int64?, at seconds: TimeInterval, type: Int = 1) -> SMSMessage {
        var message = SMSMessage(body: body, addresses: ["+1"], date: Date(timeIntervalSince1970: seconds), type: type, threadId: 1, read: true)
        message.phoneId = id
        return message
    }

    @Test func keepsRealRepeats() {
        var list = SMSPlugin.merging(message("ok", id: 1, at: 100), into: [])
        list = SMSPlugin.merging(message("ok", id: 2, at: 101), into: list)
        #expect(list.count == 2)
    }

    @Test func replacesTheSameMessage() {
        var list = SMSPlugin.merging(message("ok", id: 1, at: 100), into: [])
        list = SMSPlugin.merging(message("ok", id: 1, at: 100), into: list)
        #expect(list.count == 1)
    }

    @Test func replacesTheCopyAddedWhileSending() {
        var list = [message("on my way", id: nil, at: 100, type: 2)]
        list = SMSPlugin.merging(message("on my way", id: 7, at: 103, type: 2), into: list)
        #expect(list.count == 1)
        #expect(list.first?.phoneId == 7)
    }
}

struct SocketAddressTests {
    @Test func parsesBothFamilies() {
        #expect(SocketAddress.make(host: "192.168.1.5", port: 1716)?.storage.ss_family == sa_family_t(AF_INET))
        #expect(SocketAddress.make(host: "fd7a:115c:a1e0::1", port: 1716)?.storage.ss_family == sa_family_t(AF_INET6))
        #expect(SocketAddress.make(host: "not an address", port: 1716) == nil)
    }

    @Test func describesMappedIPv4AsIPv4() throws {
        let v4 = try #require(SocketAddress.make(host: "::ffff:192.168.1.5", port: 1716))
        let described = SocketAddress.describe(v4.storage)
        #expect(described.host == "192.168.1.5")
        #expect(described.port == 1716)
    }

    @Test func listensAndConnectsOverIPv6() throws {
        let server = SocketAddress.listener(port: 0, reusePort: false)
        #expect(server >= 0)
        defer { close(server) }
        #expect(listen(server, 1) == 0)
        var bound = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) } }
        let port = UInt16(SocketAddress.describe(bound).port)
        for host in ["::1", "127.0.0.1"] {
            var target = try #require(SocketAddress.make(host: host, port: port))
            let client = socket(Int32(target.storage.ss_family), SOCK_STREAM, 0)
            defer { close(client) }
            let connected = withUnsafePointer(to: &target.storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, target.length) }
            }
            #expect(connected == 0)
            let accepted = try #require(SocketAddress.accept(server))
            close(accepted.fd)
            #expect(accepted.host == host)
        }
    }
}

struct NotificationPacketTests {
    @Test func readsAChatNotification() {
        let packet = NetworkPacket(type: PacketType.notification, body: [
            "id": "0|com.whatsapp|1|tag|10123", "appName": "WhatsApp", "title": "Family", "text": "ignored",
            "time": "1700000000000", "groupName": "Family", "requestReplyId": "r1",
            "conversation": [["sender": "Mum", "content": "Dinner?"], ["sender": "Dad", "content": "Yes"]],
            "actions": ["Mark as read", " "],
        ])
        let item = NotificationPlugin.notification(from: packet, id: "0|com.whatsapp|1|tag|10123", deviceId: "d", image: nil)
        #expect(item.title == "Family")
        #expect(item.text == "Mum: Dinner?\nDad: Yes")
        #expect(item.replyId == "r1")
        #expect(item.actions == ["Mark as read"])
        #expect(item.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(item.packageName == "com.whatsapp")
    }

    @Test func findsACodeOnlyInAButtonWhenTheTextIsHidden() {
        let packet = NetworkPacket(type: PacketType.notification, body: [
            "id": "k", "appName": "Messages", "title": "Bank", "text": "Sensitive notification content hidden",
            "actions": ["Copy 445566"],
        ])
        let item = NotificationPlugin.notification(from: packet, id: "k", deviceId: "d", image: nil)
        #expect(item.isRedacted)
        #expect(item.code == "445566")
    }
}
