//
//  NotificationPlugin.swift
//  Tether
//

import AppKit
import Combine
import UserNotifications

/// A notification currently showing on the phone, mirrored for the in-app list.
public struct PhoneNotification: Identifiable, Hashable, Sendable {
    public let id: String
    public let deviceId: String
    public let appName: String
    public let title: String
    public let text: String
    public let date: Date
    /// Present when the phone accepts an inline reply (messaging apps).
    public let replyId: String?
    public let isDismissable: Bool
    /// A one-time verification code found in the title or text.
    public var code: String? = nil
    /// Artwork supplied by the phone; it may be a contact photo rather than an app logo.
    public var imageData: Data? = nil {
        didSet { imageIsGlyph = imageData.map(NotificationImages.isGlyph) ?? false }
    }
    /// The artwork is the app's flat status-bar icon rather than a picture.
    public private(set) var imageIsGlyph = false

    public init(id: String, deviceId: String, appName: String, title: String, text: String, date: Date,
                replyId: String?, isDismissable: Bool, code: String? = nil, imageData: Data? = nil) {
        self.id = id
        self.deviceId = deviceId
        self.appName = appName
        self.title = title
        self.text = text
        self.date = date
        self.replyId = replyId
        self.isDismissable = isDismissable
        self.code = code
        self.imageData = imageData
        self.imageIsGlyph = imageData.map(NotificationImages.isGlyph) ?? false
    }
}

public final class NotificationPlugin: NSObject, ObservableObject, TetherPlugin, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Active phone notifications per device, newest first.
    @Published public private(set) var notifications: [String: [PhoneNotification]] = [:]

    public let supportedPacketTypes = [
        "kdeconnect.notification",
        "kdeconnect.notification.request",
        "kdeconnect.notification.reply"
    ]

    private let images = NotificationImages()
    private var imageTracker = NotificationImageTracker()

    private var activeConnections: [String: DeviceConnection] = [:]

    public override init() {
        super.init()
        setupNotificationCategories()
        UNUserNotificationCenter.current().delegate = self
        requestPermission()
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            TetherLog("[NotificationPlugin] Notification authorization granted: \(granted)\(error != nil ? ", error: \(error!)" : "")")
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            TetherLog("[NotificationPlugin] Current notification authorization status: \(settings.authorizationStatus.rawValue) (0=notDetermined, 1=denied, 2=authorized, 3=provisional)")
        }
    }

    private func setupNotificationCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: "TETHER_REPLY_ACTION",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply..."
        )

        let dismissAction = UNNotificationAction(
            identifier: "TETHER_DISMISS_ACTION",
            title: "Dismiss on Phone",
            options: [.destructive]
        )

        let category = UNNotificationCategory(
            identifier: "TETHER_NOTIFICATION_CATEGORY",
            actions: [replyAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        let acceptAction = UNNotificationAction(
            identifier: "TETHER_PAIR_ACCEPT_ACTION",
            title: "Accept",
            options: [.foreground]
        )

        let rejectAction = UNNotificationAction(
            identifier: "TETHER_PAIR_REJECT_ACTION",
            title: "Reject",
            options: [.destructive]
        )

        let pairCategory = UNNotificationCategory(
            identifier: "TETHER_PAIR_REQUEST_CATEGORY",
            actions: [acceptAction, rejectAction],
            intentIdentifiers: [],
            options: []
        )

        let copyCodeAction = UNNotificationAction(
            identifier: "TETHER_COPY_CODE_ACTION",
            title: "Copy Code",
            options: []
        )

        let codeCategory = UNNotificationCategory(
            identifier: "TETHER_CODE_CATEGORY",
            actions: [copyCodeAction, replyAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        let muteAction = UNNotificationAction(
            identifier: TelephonyPlugin.muteAction,
            title: "Mute Ringer",
            options: []
        )

        let callCategory = UNNotificationCategory(
            identifier: TelephonyPlugin.callCategory,
            actions: [muteAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category, codeCategory, pairCategory, callCategory])
    }

    public func onConnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let paired = TrustStore.shared.pairedDevice(for: deviceId),
              paired.isNotificationSyncEnabled else {
            return
        }
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
            if activeConnections[deviceId] === connection {
                activeConnections.removeValue(forKey: deviceId)
                imageTracker.removeDevice(deviceId)
                images.removeAll()
                // The phone re-sends everything it is still showing on reconnect.
                notifications[deviceId] = nil
            }
        }
    }

    // MARK: - Actions

    /// Sends an inline reply for a notification that offered one.
    public func reply(to notification: PhoneNotification, text: String) {
        guard let replyId = notification.replyId,
              let connection = activeConnections[notification.deviceId] else { return }
        connection.send(packet: NetworkPacket(
            type: "kdeconnect.notification.reply",
            body: ["requestReplyId": replyId, "message": text]
        ))
        TetherLog("[NotificationPlugin] Sent notification reply to \(notification.deviceId)")
    }

    /// Asks the phone to dismiss a notification; the phone confirms with a cancel packet.
    public func dismiss(_ notification: PhoneNotification) {
        if let connection = activeConnections[notification.deviceId] {
            connection.send(packet: NetworkPacket(
                type: "kdeconnect.notification.request",
                body: ["cancel": notification.id]
            ))
        }
        removeLocally(id: notification.id, deviceId: notification.deviceId)
    }

    /// Puts a verification code on the clipboard.
    public static func copyToPasteboard(_ code: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
    }

    private func removeLocally(id: String, deviceId: String) {
        imageTracker.remove(.init(deviceId: deviceId, notificationId: id))
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier(deviceId: deviceId, id: id)])
        notifications[deviceId]?.removeAll { $0.id == id }
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
            removeLocally(id: notifId, deviceId: deviceId)
            return
        }

        let appName = packet.string(for: "appName") ?? "Notification"
        let title = packet.string(for: "title") ?? ""
        let text = packet.string(for: "text") ?? (packet.string(for: "ticker") ?? "")
        let silent = packet.bool(for: "silent")
        let replyId = packet.string(for: "requestReplyId").flatMap { $0.isEmpty ? nil : $0 }
        let timeMillis = packet.int64(for: "time")

        let item = PhoneNotification(
            id: notifId,
            deviceId: deviceId,
            appName: appName,
            title: title,
            text: text,
            date: timeMillis > 0 ? Date(timeIntervalSince1970: TimeInterval(timeMillis) / 1000) : Date(),
            replyId: replyId,
            isDismissable: packet.bool(for: "isClearable", default: true),
            code: OneTimeCode.find(in: title + "\n" + text),
            imageData: images.image(deviceId: deviceId, hash: packet.string(for: "payloadHash"))
        )
        var list = notifications[deviceId] ?? []
        list.removeAll { $0.id == notifId }
        list.insert(item, at: 0)
        list.sort { $0.date > $1.date }
        notifications[deviceId] = list

        let key = NotificationImageTracker.Key(deviceId: deviceId, notificationId: notifId)
        let suppressNativeDuplicate = NativeNotificationFilter.shouldSuppress(item)
        let waitForImage = !silent && !suppressNativeDuplicate && item.imageData == nil && Self.expectsImage(packet)
        let token = imageTracker.begin(key, packetId: packet.id, hash: packet.string(for: "payloadHash"), waiting: waitForImage)

        // Silent initial sync still populates the list and image cache.
        // Also keep mirrored WhatsApp items without duplicating native alerts.
        if silent || suppressNativeDuplicate { return }

        if let code = item.code, UserDefaults.standard.bool(forKey: OneTimeCode.autoCopyKey) {
            Self.copyToPasteboard(code)
            TetherLog("[NotificationPlugin] Copied a verification code from \(appName)")
        }

        if waitForImage {
            // Never hold up an alert for a slow/broken image transfer. A late
            // image enriches the in-app list without posting a second banner.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.finishWaiting(key, token: token)
            }
        } else {
            post(item)
        }
    }

    static func expectsImage(_ packet: NetworkPacket) -> Bool {
        guard let size = packet.payloadSize, size > 0,
              size <= NotificationImages.maximumPayloadSize,
              let rawPort = packet.payloadTransferInfo?["port"]?.value else { return false }
        let port: Int?
        switch rawPort {
        case let value as Int: port = value
        case let value as Int64: port = Int(exactly: value)
        case let value as String: port = Int(value)
        default: port = nil
        }
        return port.map { (1...65535).contains($0) } ?? false
    }

    public func handlePayload(connection: DeviceConnection, packet: NetworkPacket, fileURL: URL) {
        guard packet.type == "kdeconnect.notification",
              let deviceId = connection.peerDeviceInfo?.deviceId,
              activeConnections[deviceId] === connection,
              TrustStore.shared.pairedDevice(for: deviceId)?.isNotificationSyncEnabled == true,
              let id = packet.string(for: "id") else { return }
        let key = NotificationImageTracker.Key(deviceId: deviceId, notificationId: id)
        guard let token = imageTracker.token(for: key, packetId: packet.id, hash: packet.string(for: "payloadHash")) else { return }
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 0, size <= NotificationImages.maximumPayloadSize,
           let data = try? Data(contentsOf: fileURL),
           let png = images.store(data, deviceId: deviceId, hash: packet.string(for: "payloadHash")),
           let index = notifications[deviceId]?.firstIndex(where: { $0.id == id }) {
            notifications[deviceId]?[index].imageData = png
        }
        finishWaiting(key, token: token)
    }

    public func handlePayloadFailure(connection: DeviceConnection, packet: NetworkPacket, error: Error) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              activeConnections[deviceId] === connection,
              let id = packet.string(for: "id") else { return }
        let key = NotificationImageTracker.Key(deviceId: deviceId, notificationId: id)
        if let token = imageTracker.token(for: key, packetId: packet.id) {
            finishWaiting(key, token: token)
        }
    }

    private func finishWaiting(_ key: NotificationImageTracker.Key, token: UUID) {
        guard imageTracker.takeWaiting(key, token: token),
              TrustStore.shared.pairedDevice(for: key.deviceId)?.isNotificationSyncEnabled == true,
              let item = notifications[key.deviceId]?.first(where: { $0.id == key.notificationId }) else { return }
        post(item)
    }

    // Device IDs scope both image revisions and Notification Center identifiers.
    static func identifier(deviceId: String, id: String) -> String {
        "android:\(deviceId.utf8.count):\(deviceId)\(id)"
    }

    private func post(_ item: PhoneNotification) {
        // Recheck after an image wait: WhatsApp may have launched meanwhile.
        guard !NativeNotificationFilter.shouldSuppress(item) else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title.isEmpty ? item.appName : "\(item.appName): \(item.title)"
        content.body = item.text
        content.sound = .default
        content.categoryIdentifier = item.code == nil ? "TETHER_NOTIFICATION_CATEGORY" : "TETHER_CODE_CATEGORY"
        content.userInfo = [
            "deviceId": item.deviceId,
            "notifId": item.id,
            "appName": item.appName,
            "replyId": item.replyId ?? "",
            "code": item.code ?? ""
        ]
        if let code = item.code {
            content.subtitle = UserDefaults.standard.bool(forKey: OneTimeCode.autoCopyKey)
                ? "Code \(code) copied"
                : "Code \(code)"
        }

        // A status-bar glyph says nothing the banner doesn't, and is usually
        // white, so only pictures are attached.
        let prepared = item.imageIsGlyph ? nil : item.imageData.flatMap { NotificationImages.attachment($0) }
        if let prepared { content.attachments = [prepared.attachment] }

        let request = UNNotificationRequest(
            identifier: Self.identifier(deviceId: item.deviceId, id: item.id),
            content: content,
            trigger: nil
        )

        let key = NotificationImageTracker.Key(deviceId: item.deviceId, notificationId: item.id)
        let token = imageTracker.currentToken(for: key)
        Task { @MainActor [weak self] in
            // Keep the source until scheduling has finished: the system moves
            // the file when adding the request, not when creating the attachment.
            defer { prepared?.removeSource() }
            guard let self, self.imageTracker.currentToken(for: key) == token,
                  self.notifications[item.deviceId]?.contains(where: { $0.id == item.id }) == true,
                  TrustStore.shared.pairedDevice(for: item.deviceId)?.isNotificationSyncEnabled == true,
                  !NativeNotificationFilter.shouldSuppress(item) else { return }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                TetherLog("[NotificationPlugin] Failed to display notification: \(error)")
                guard prepared != nil, self.imageTracker.currentToken(for: key) == token,
                      self.notifications[item.deviceId]?.contains(where: { $0.id == item.id }) == true,
                      TrustStore.shared.pairedDevice(for: item.deviceId)?.isNotificationSyncEnabled == true,
                      !NativeNotificationFilter.shouldSuppress(item) else { return }
                // A rejected attachment must not suppress the text notification.
                content.attachments = []
                let fallback = UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil)
                do {
                    try await UNUserNotificationCenter.current().add(fallback)
                } catch {
                    TetherLog("[NotificationPlugin] Text fallback failed: \(error)")
                }
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
        if response.notification.request.content.categoryIdentifier == UpdateController.notificationCategory {
            Task { @MainActor in UpdateController.shared.showWindow() }
            completionHandler()
            return
        }

        if response.actionIdentifier == "TETHER_PAIR_ACCEPT_ACTION" {
            let info = response.notification.request.content.userInfo
            let deviceId = info["deviceId"] as? String ?? ""
            let fingerprint = info["fingerprint"] as? String
            DispatchQueue.main.async {
                TetherService.shared.acceptIncomingPairRequest(deviceId: deviceId, fingerprint: fingerprint)
            }
            completionHandler()
            return
        } else if response.actionIdentifier == "TETHER_PAIR_REJECT_ACTION" {
            DispatchQueue.main.async {
                TetherService.shared.rejectIncomingPairRequest()
            }
            completionHandler()
            return
        }

        let userInfo = response.notification.request.content.userInfo
        if response.actionIdentifier == TelephonyPlugin.muteAction {
            if let deviceId = userInfo["deviceId"] as? String {
                TelephonyPlugin.muteRinger(deviceId: deviceId)
            }
            completionHandler()
            return
        }

        // Copying needs no connection: the code is in the notification.
        if response.actionIdentifier == "TETHER_COPY_CODE_ACTION" {
            if let code = userInfo["code"] as? String, !code.isEmpty {
                Self.copyToPasteboard(code)
            }
            completionHandler()
            return
        }

        // Opening the Mac app is a local action, so it also works if the
        // phone has disconnected since this notification was delivered.
        if let id = userInfo["notifId"] as? String,
           let bundleIdentifier = NativeNotificationFilter.applicationForDefaultAction(
               response.actionIdentifier,
               appName: userInfo["appName"] as? String ?? "",
               notificationId: id
           ) {
            DispatchQueue.main.async {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                    TetherLog("[NotificationPlugin] Native WhatsApp is not installed")
                    completionHandler()
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    if let error { TetherLog("[NotificationPlugin] Could not open native WhatsApp: \(error)") }
                    completionHandler()
                }
            }
            return
        }

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
            TetherLog("[NotificationPlugin] Sent notification reply to \(deviceId): \(replyText)")
        } else if response.actionIdentifier == "TETHER_DISMISS_ACTION" {
            if let notifId = userInfo["notifId"] as? String {
                let dismissPacket = NetworkPacket(
                    type: "kdeconnect.notification.request",
                    body: ["cancel": notifId]
                )
                connection.send(packet: dismissPacket)
                removeLocally(id: notifId, deviceId: deviceId)
                TetherLog("[NotificationPlugin] Sent dismiss request for \(notifId)")
            }
        }

        completionHandler()
    }
}
