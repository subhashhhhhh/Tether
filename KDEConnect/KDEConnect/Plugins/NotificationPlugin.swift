//
//  NotificationPlugin.swift
//  KDEConnect
//

import Foundation
import UserNotifications

public final class NotificationPlugin: NSObject, KDEConnectPlugin, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public let supportedPacketTypes = [
        "kdeconnect.notification",
        "kdeconnect.notification.request",
        "kdeconnect.notification.reply"
    ]

    private var activeConnections: [String: DeviceConnection] = [:]

    public override init() {
        super.init()
        setupNotificationCategories()
        UNUserNotificationCenter.current().delegate = self
        requestPermission()
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("[NotificationPlugin] Notification authorization granted: \(granted)")
        }
    }

    private func setupNotificationCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: "KDE_REPLY_ACTION",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply..."
        )

        let dismissAction = UNNotificationAction(
            identifier: "KDE_DISMISS_ACTION",
            title: "Dismiss on Phone",
            options: [.destructive]
        )

        let category = UNNotificationCategory(
            identifier: "KDE_NOTIFICATION_CATEGORY",
            actions: [replyAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    public func onConnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        activeConnections[deviceId] = connection

        // Request active notifications from remote phone
        let requestPacket = NetworkPacket(
            type: "kdeconnect.notification.request",
            body: ["request": true]
        )
        connection.send(packet: requestPacket)
    }

    public func onDisconnected(connection: DeviceConnection) {
        if let deviceId = connection.peerDeviceInfo?.deviceId {
            activeConnections.removeValue(forKey: deviceId)
        }
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.notification" else { return }

        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let paired = TrustStore.shared.pairedDevice(for: deviceId),
              paired.isNotificationSyncEnabled else {
            return
        }

        let isCancel = packet.bool(for: "isCancel")
        guard let notifId = packet.string(for: "id") else { return }

        if isCancel {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notifId])
            return
        }

        let appName = packet.string(for: "appName") ?? "Notification"
        let title = packet.string(for: "title") ?? ""
        let text = packet.string(for: "text") ?? (packet.string(for: "ticker") ?? "")
        let silent = packet.bool(for: "silent")
        let replyId = packet.string(for: "requestReplyId")

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? appName : "\(appName): \(title)"
        content.body = text
        if !silent {
            content.sound = .default
        }
        content.categoryIdentifier = "KDE_NOTIFICATION_CATEGORY"
        content.userInfo = [
            "deviceId": deviceId,
            "notifId": notifId,
            "replyId": replyId ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: notifId,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationPlugin] Failed to display notification: \(error)")
            }
        }
    }

    // UNUserNotificationCenterDelegate
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let deviceId = userInfo["deviceId"] as? String,
              let connection = activeConnections[deviceId] else {
            completionHandler()
            return
        }

        if let textResponse = response as? UNTextInputNotificationResponse,
           let replyId = userInfo["replyId"] as? String, !replyId.isEmpty {
            let replyText = textResponse.userText
            let replyPacket = NetworkPacket(
                type: "kdeconnect.notification.reply",
                body: [
                    "requestReplyId": replyId,
                    "message": replyText
                ]
            )
            connection.send(packet: replyPacket)
            print("[NotificationPlugin] Sent notification reply to \(deviceId): \(replyText)")
        } else if response.actionIdentifier == "KDE_DISMISS_ACTION" {
            if let notifId = userInfo["notifId"] as? String {
                let dismissPacket = NetworkPacket(
                    type: "kdeconnect.notification.request",
                    body: ["cancel": notifId]
                )
                connection.send(packet: dismissPacket)
                print("[NotificationPlugin] Sent dismiss request for \(notifId)")
            }
        }

        completionHandler()
    }
}
