//
//  TelephonyPlugin.swift
//  Tether
//

import AppKit
import UserNotifications

/// Incoming call and messaging events from the phone.
///
/// The peer sends `kdeconnect.telephony` with `event` set to `ringing`,
/// `missedCall`, `talking` or `sms`, plus `phoneNumber`, and `contactName` and
/// a JPEG `phoneThumbnail` when the phone knows the caller. `isCancel` marks a
/// previously announced event as no longer relevant.
final class TelephonyPlugin: TetherPlugin, @unchecked Sendable {
    static let requestMuteType = PacketType.telephonyRequestMute
    static let callCategory = "TETHER_CALL_CATEGORY"
    static let muteAction = "TETHER_MUTE_RINGER_ACTION"

    let supportedPacketTypes = [PacketType.telephony]

    init() {}

    func onConnected(connection: DeviceConnection) {}
    func onDisconnected(connection: DeviceConnection) {}

    func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == PacketType.telephony,
              let deviceId = connection.peerDeviceInfo?.deviceId else { return }

        let event = packet.string(for: "event") ?? ""
        let identifier = "tether-telephony-\(deviceId)-\(event)"
        let isCall = event == "ringing" || event == "talking"
        TetherLog("[TelephonyPlugin] \(event)\(packet.bool(for: "isCancel") ? " cancelled" : "") from \(connection.peerDeviceInfo?.deviceName ?? deviceId)")

        // A cancel retracts what was posted for this event; for a call, it ended.
        if packet.bool(for: "isCancel") {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            if isCall {
                Task { @MainActor in
                    CallMediaPauser.shared.callEnded(deviceId)
                    CallCard.shared.ended(deviceId: deviceId)
                }
            }
            return
        }
        if isCall {
            Task { @MainActor in CallMediaPauser.shared.callStarted(deviceId) }
        }

        // The phone's own contact name wins; otherwise Tether's copy of the
        // contacts; otherwise the number.
        let number = packet.string(for: "phoneNumber")
        let contact = number.flatMap { TetherService.shared.contactsPlugin.contactNow(for: $0, on: deviceId) }
        let name = packet.string(for: "contactName").flatMap { $0.isEmpty ? nil : $0 } ?? contact?.name
        let who = name ?? number ?? "Unknown number"
        let photo = packet.string(for: "phoneThumbnail").flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
            ?? contact?.photo

        // Calls go to the floating card instead of a banner; a missed call
        // closes it and is posted as usual.
        if CallCard.isEnabled, event == "ringing" || event == "talking" || event == "missedCall" {
            let caller = CallCard.Caller(
                name: who, isContact: name != nil, number: name != nil ? number : nil,
                photo: photo.flatMap(NSImage.init(data:)),
                deviceName: connection.peerDeviceInfo?.deviceName ?? "your phone"
            )
            Task { @MainActor in
                switch event {
                case "ringing": CallCard.shared.ringing(deviceId: deviceId, caller: caller)
                case "talking": CallCard.shared.talking(deviceId: deviceId, caller: caller)
                default: CallCard.shared.missed(deviceId: deviceId)
                }
            }
            if event != "missedCall" { return }
        }

        guard let content = Self.banner(for: event, who: who, number: name != nil ? number : nil, deviceId: deviceId,
                                        messageBody: packet.string(for: "messageBody")) else {
            TetherLog("[TelephonyPlugin] Ignoring unknown telephony event '\(event)'")
            return
        }
        if let photo, let attachment = Self.attachment(photo) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                TetherLog("[TelephonyPlugin] Failed to post notification: \(error)")
            }
        }
    }

    /// The banner for a call event, or nil for an event Tether doesn't show.
    /// `number` is shown under a contact's name, so it's nil when `who` is
    /// already the number.
    static func banner(for event: String, who: String, number: String?, deviceId: String,
                       messageBody: String?) -> UNMutableNotificationContent? {
        let content = UNMutableNotificationContent()
        switch event {
        case "ringing":
            content.title = who
            content.subtitle = "Incoming call"
            if let number { content.body = number }
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.categoryIdentifier = Self.callCategory
            content.userInfo = ["deviceId": deviceId]
        case "missedCall":
            content.title = who
            content.subtitle = "Missed call"
            if let number { content.body = number }
            content.sound = .default
        case "talking":
            content.title = who
            content.subtitle = "Call in progress"
        case "sms":
            content.title = "Message from \(who)"
            content.body = messageBody ?? ""
        default:
            return nil
        }
        return content
    }

    /// Asks the phone to silence its ringer, from the incoming-call notification.
    static func muteRinger(deviceId: String) {
        guard let connection = TetherService.shared.connection(for: deviceId) else { return }
        connection.send(packet: NetworkPacket(type: requestMuteType))
        TetherLog("[TelephonyPlugin] Asked the phone to mute its ringer")
    }

    /// The caller's photo as a notification attachment. The notification
    /// center moves the file into its own store.
    private static func attachment(_ photo: Data) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-caller-\(UUID().uuidString).jpg")
        guard (try? photo.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "photo", url: url, options: nil)
    }
}
