//
//  TelephonyPlugin.swift
//  Tether
//

import Foundation
import UserNotifications

/// Incoming call and messaging events from the phone.
///
/// The peer sends `kdeconnect.telephony` with `event` set to `ringing`,
/// `missedCall`, `talking` or `sms`, plus `phoneNumber` and `contactName` when
/// known. `isCancel` marks a previously announced event as no longer relevant.
public final class TelephonyPlugin: TetherPlugin, @unchecked Sendable {

    public let supportedPacketTypes = ["kdeconnect.telephony"]

    public init() {}

    public func onConnected(connection: DeviceConnection) {}
    public func onDisconnected(connection: DeviceConnection) {}

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.telephony" else { return }

        let event = packet.string(for: "event") ?? ""
        let isCancel = packet.bool(for: "isCancel")
        let contact = packet.string(for: "contactName")
        let number = packet.string(for: "phoneNumber")
        let who = contact?.isEmpty == false ? contact! : (number ?? "Unknown number")

        // A cancel tells us to retract whatever we posted for this event.
        if isCancel {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["tether-telephony-\(event)"])
            return
        }

        let content = UNMutableNotificationContent()
        switch event {
        case "ringing":
            content.title = "Incoming call"
            content.body = who
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        case "missedCall":
            content.title = "Missed call"
            content.body = who
            content.sound = .default
        case "talking":
            content.title = "Call in progress"
            content.body = who
        case "sms":
            content.title = "Message from \(who)"
            content.body = packet.string(for: "messageBody") ?? ""
        default:
            TetherLog("[TelephonyPlugin] Ignoring unknown telephony event '\(event)'")
            return
        }

        let request = UNNotificationRequest(
            identifier: "tether-telephony-\(event)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                TetherLog("[TelephonyPlugin] Failed to post notification: \(error)")
            }
        }
    }
}
