//
//  NotificationParsingTests.swift
//  TetherTests
//

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
