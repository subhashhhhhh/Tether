//
//  PingPlugin.swift
//  Tether
//

import Foundation
import UserNotifications

public final class PingPlugin: TetherPlugin, @unchecked Sendable {
    public let supportedPacketTypes = ["kdeconnect.ping"]

    public init() {}

    public func onConnected(connection: DeviceConnection) {}
    public func onDisconnected(connection: DeviceConnection) {}

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.ping" else { return }

        let message = packet.string(for: "message") ?? "Ping!"
        let deviceName = connection.peerDeviceInfo?.deviceName ?? "Device"

        let content = UNMutableNotificationContent()
        content.title = "Ping from \(deviceName)"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[PingPlugin] Error delivering ping notification: \(error)")
            }
        }
    }

    public func sendPing(to connection: DeviceConnection, message: String? = nil) {
        var body: [String: Any] = [:]
        if let msg = message, !msg.isEmpty {
            body["message"] = msg
        }
        let packet = NetworkPacket(type: "kdeconnect.ping", body: body)
        connection.send(packet: packet)
    }
}
