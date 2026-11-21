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
    /// The notification's own buttons on the phone ("Mark as read", "Mute").
    public var actions: [String] = []
    /// A chat notification's recent messages, oldest first.
    public var conversation: [ConversationLine] = []
    /// A group chat's name; nil for a one-to-one chat.
    public var groupName: String? = nil
    /// Android 15 replaced the text with "Sensitive notification content hidden".
    public var isRedacted = false

    public struct ConversationLine: Hashable, Sendable {
        public let sender: String
        public let content: String
    }

    /// The Android package, from the notification's key
    /// ("user|package|id|tag|uid"); nil for a key in another form.
    public var packageName: String? {
        let fields = id.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count >= 5, Int(fields[0]) != nil, !fields[1].isEmpty else { return nil }
        return String(fields[1])
    }

    /// What an app's glyph is stored under: its package, so two apps with
    /// the same name don't share one, else its name.
    public var glyphKey: String { packageName ?? appName }

    /// From Android itself, which uses a different icon for each kind of
    /// notification (battery, Wi-Fi, USB), so its icon belongs to the
    /// notification, not to an app.
    public var isFromSystem: Bool {
        if let packageName { return packageName == "android" || packageName == "com.android.systemui" }
        return appName == "Android System" || appName == "System UI"
    }

    /// Which chat or thread it belongs to, for grouping banners.
    public var threadKey: String { "\(glyphKey)|\(groupName ?? title)" }
    /// A one-time verification code found in the title or text.
    public var code: String? = nil
    /// Artwork supplied by the phone; it may be a contact photo rather than an app logo.
    public var imageData: Data? = nil {
        didSet { imageIsGlyph = imageData.map(NotificationImages.isGlyph) ?? false }
    }
    /// The artwork is the app's flat status-bar icon rather than a picture.
    public private(set) var imageIsGlyph = false

    public init(id: String, deviceId: String, appName: String, title: String, text: String, date: Date,
                replyId: String?, isDismissable: Bool, code: String? = nil, imageData: Data? = nil,
                actions: [String] = []) {
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
        self.actions = actions
    }
}

public final class NotificationPlugin: NSObject, ObservableObject, TetherPlugin, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Active phone notifications per device, newest first.
    @Published public private(set) var notifications: [String: [PhoneNotification]] = [:]
    /// Each app's status-bar glyph, by device then package (app name for
    /// glyphs saved before packages were used). The phone sends
    /// it for a notification with no picture of its own, and it is the one
    /// image that stands for the app rather than for a person, so it's kept
    /// and shown for every notification from that app.
    @Published public private(set) var appGlyphs: [String: [String: Data]] = [:]

    public let supportedPacketTypes = [
        PacketType.notification,
        PacketType.notificationRequest,
        PacketType.notificationReply
    ]

    private let images = NotificationImages()
    private var imageTracker = NotificationImageTracker()

    private var activeConnections: [String: DeviceConnection] = [:]
    /// Devices whose notifications are being mirrored right now.
    private var syncingDevices: Set<String> = []
    private var settingsObserver: AnyCancellable?

    public override init() {
        super.init()
        setupNotificationCategories()
        UNUserNotificationCenter.current().delegate = self
        requestPermission()
        // "Show phone notifications" can change while the phone is connected.
        settingsObserver = TrustStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySyncSettings() }
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

        // Reply is offered only where the phone offered it; typing into a
        // field that goes nowhere loses the text.
        let category = UNNotificationCategory(
            identifier: Self.plainCategory,
            actions: [dismissAction],
            intentIdentifiers: [],
            options: []
        )
        let replyCategory = UNNotificationCategory(
            identifier: Self.replyCategory,
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
            identifier: Self.codeCategory,
            actions: [copyCodeAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        let codeReplyCategory = UNNotificationCategory(
            identifier: Self.codeReplyCategory,
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

        UNUserNotificationCenter.current().setNotificationCategories(
            [category, replyCategory, codeCategory, codeReplyCategory, pairCategory, callCategory])
    }

    /// How long after asking for the phone's notifications they're all in,
    /// so banners for anything else can be cleared.
    static let resyncSettleTime: TimeInterval = 6
    /// How long a banner waits for its picture before showing without it.
    static let imageWait: TimeInterval = 1

    static let plainCategory = "TETHER_NOTIFICATION_CATEGORY"
    static let replyCategory = "TETHER_REPLY_CATEGORY"
    static let codeCategory = "TETHER_CODE_CATEGORY"
    static let codeReplyCategory = "TETHER_CODE_REPLY_CATEGORY"

    static func category(hasCode: Bool, hasReply: Bool) -> String {
        switch (hasCode, hasReply) {
        case (false, false): plainCategory
        case (false, true): replyCategory
        case (true, false): codeCategory
        case (true, true): codeReplyCategory
        }
    }

    public func onConnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let paired = TrustStore.shared.pairedDevice(for: deviceId) else {
            return
        }
        // Kept even with mirroring off, so turning it on later works without
        // a reconnect.
        activeConnections[deviceId] = connection
        loadGlyphsIfNeeded(for: deviceId)
        if paired.isNotificationSyncEnabled { startSync(deviceId: deviceId, connection: connection) }
    }

    /// The phone keeps showing what it showed; only the connection moves.
    /// Asking again would have it resend every notification and picture.
    public func onConnectionReplaced(old: DeviceConnection, new: DeviceConnection) {
        guard let deviceId = new.peerDeviceInfo?.deviceId else { return }
        guard activeConnections[deviceId] != nil else {
            onConnected(connection: new)
            return
        }
        activeConnections[deviceId] = new
    }

    private func startSync(deviceId: String, connection: DeviceConnection) {
        syncingDevices.insert(deviceId)
        connection.send(packet: NetworkPacket(
            type: PacketType.notificationRequest,
            body: ["request": true]
        ))
        // The phone answers with everything it is showing. Once that's in,
        // a banner for anything else was dismissed while we were apart.
        let connectionId = ObjectIdentifier(connection)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resyncSettleTime) { [weak self] in
            guard let self, self.activeConnections[deviceId].map(ObjectIdentifier.init) == connectionId,
                  self.syncingDevices.contains(deviceId) else { return }
            self.removeDeliveredBanners(deviceId: deviceId, keepingListed: true)
        }
    }

    /// Follows "Show phone notifications" being switched while connected.
    private func applySyncSettings() {
        for (deviceId, connection) in activeConnections {
            let enabled = TrustStore.shared.pairedDevice(for: deviceId)?.isNotificationSyncEnabled == true
            if enabled, !syncingDevices.contains(deviceId) {
                startSync(deviceId: deviceId, connection: connection)
            } else if !enabled, syncingDevices.remove(deviceId) != nil {
                imageTracker.removeDevice(deviceId)
                notifications[deviceId] = nil
                removeDeliveredBanners(deviceId: deviceId, keepingListed: false)
            }
        }
    }

    /// Takes this device's banners out of Notification Center: all of them,
    /// or only those the phone is no longer showing.
    private func removeDeliveredBanners(deviceId: String, keepingListed: Bool) {
        let prefix = Self.identifier(deviceId: deviceId, id: "")
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let identifiers = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            guard !identifiers.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Read here, not before the fetch, so one that arrived meanwhile is kept.
                let listed = keepingListed
                    ? Set((self.notifications[deviceId] ?? []).map { Self.identifier(deviceId: deviceId, id: $0.id) })
                    : []
                let stale = identifiers.filter { !listed.contains($0) }
                guard !stale.isEmpty else { return }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
                TetherLog("[NotificationPlugin] Removed \(stale.count) banner(s) no longer on the phone")
            }
        }
    }

    public func onDisconnected(connection: DeviceConnection) {
        if let deviceId = connection.peerDeviceInfo?.deviceId {
            if activeConnections[deviceId] === connection {
                activeConnections.removeValue(forKey: deviceId)
                syncingDevices.remove(deviceId)
                imageTracker.removeDevice(deviceId)
                // The artwork cache stays: after a reconnect the phone names
                // pictures it already sent by hash and doesn't send them again.
                // The phone re-sends everything it is still showing on reconnect.
                notifications[deviceId] = nil
            }
        }
    }

    // MARK: - Actions

    /// Whether the picture with this hash is already stored.
    public func hasImage(deviceId: String, hash: String) -> Bool {
        images.image(deviceId: deviceId, hash: hash) != nil
    }

    /// Sends an inline reply for a notification that offered one.
    public func reply(to notification: PhoneNotification, text: String) {
        guard let replyId = notification.replyId,
              let connection = activeConnections[notification.deviceId] else { return }
        connection.send(packet: NetworkPacket(
            type: PacketType.notificationReply,
            body: ["requestReplyId": replyId, "message": text]
        ))
        TetherLog("[NotificationPlugin] Sent notification reply to \(notification.deviceId)")
    }

    // MARK: - App glyphs

    private static let glyphQueue = DispatchQueue(label: "com.subhashh.tether.app-glyphs", qos: .utility)

    private static func glyphFile(for deviceId: String) -> URL? {
        // The ID comes from the peer; only a plain one names a file.
        guard !deviceId.isEmpty, deviceId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("Tether/AppGlyphs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(deviceId + ".plist")
    }

    /// Reads a device's saved glyphs the first time they're needed.
    private func loadGlyphsIfNeeded(for deviceId: String) {
        guard appGlyphs[deviceId] == nil else { return }
        appGlyphs[deviceId] = [:]
        guard let url = Self.glyphFile(for: deviceId) else { return }
        Self.glyphQueue.async {
            guard let data = try? Data(contentsOf: url),
                  let saved = try? PropertyListDecoder().decode([String: Data].self, from: data) else { return }
            DispatchQueue.main.async {
                // What arrived meanwhile is newer than what was saved.
                self.appGlyphs[deviceId] = saved.merging(self.appGlyphs[deviceId] ?? [:]) { _, new in new }
            }
        }
    }

    private func rememberGlyph(of item: PhoneNotification) {
        loadGlyphsIfNeeded(for: item.deviceId)
        guard item.imageIsGlyph, !item.isFromSystem, let glyph = item.imageData,
              appGlyphs[item.deviceId]?[item.glyphKey] != glyph else { return }
        appGlyphs[item.deviceId, default: [:]][item.glyphKey] = glyph
        guard let url = Self.glyphFile(for: item.deviceId), let glyphs = appGlyphs[item.deviceId] else { return }
        Self.glyphQueue.async {
            if let data = try? PropertyListEncoder().encode(glyphs) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Presses one of the notification's own buttons on the phone.
    public func perform(_ action: String, on notification: PhoneNotification) {
        guard let connection = activeConnections[notification.deviceId] else { return }
        connection.send(packet: NetworkPacket(
            type: PacketType.notificationAction,
            body: ["key": notification.id, "action": action]
        ))
        TetherLog("[NotificationPlugin] Sent notification action to \(notification.deviceId)")
    }

    /// Asks the phone to dismiss a notification; the phone confirms with a cancel packet.
    public func dismiss(_ notification: PhoneNotification) {
        if let connection = activeConnections[notification.deviceId] {
            connection.send(packet: NetworkPacket(
                type: PacketType.notificationRequest,
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
        guard packet.type == PacketType.notification else { return }

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
        var title = packet.string(for: "title") ?? ""
        var text = packet.string(for: "text") ?? (packet.string(for: "ticker") ?? "")
        let silent = packet.bool(for: "silent")
        // A chat sends its recent messages with their senders, as the
        // desktop app shows them: the chat's name as the title, then each
        // message under its sender.
        let groupName = packet.string(for: "groupName").flatMap { $0.isEmpty ? nil : $0 }
        let conversation = packet.objectArray(for: "conversation").compactMap { line -> PhoneNotification.ConversationLine? in
            guard let content = line["content"] as? String, !content.isEmpty else { return nil }
            return .init(sender: line["sender"] as? String ?? "", content: content)
        }
        if let first = conversation.first {
            title = groupName ?? (first.sender.isEmpty ? title : first.sender)
            text = Self.plainText(of: conversation, title: title)
        }
        let isRedacted = Self.isRedacted(text)
        let actions = packet.stringArray(for: "actions").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let replyId = packet.string(for: "requestReplyId").flatMap { $0.isEmpty ? nil : $0 }
        let timeMillis = packet.int64(for: "time")

        var item = PhoneNotification(
            id: notifId,
            deviceId: deviceId,
            appName: appName,
            title: title,
            text: text,
            date: timeMillis > 0 ? Date(timeIntervalSince1970: TimeInterval(timeMillis) / 1000) : Date(),
            replyId: replyId,
            isDismissable: packet.bool(for: "isClearable", default: true),
            // Hidden text has nothing to find, and a "Copy 123456" button
            // carries the code when the text doesn't.
            code: isRedacted ? OneTimeCode.find(inAction: actions) : (OneTimeCode.find(in: title + "\n" + text) ?? OneTimeCode.find(inAction: actions)),
            imageData: images.image(deviceId: deviceId, hash: packet.string(for: "payloadHash")),
            // The phone can send a button with no title; there's nothing to show for it.
            actions: actions
        )
        item.conversation = conversation
        item.groupName = groupName
        item.isRedacted = isRedacted
        rememberGlyph(of: item)
        var list = notifications[deviceId] ?? []
        let isUpdate = list.contains { $0.id == notifId }
        list.removeAll { $0.id == notifId }
        list.insert(item, at: 0)
        list.sort { $0.date > $1.date }
        notifications[deviceId] = list

        let key = NotificationImageTracker.Key(deviceId: deviceId, notificationId: notifId)
        let suppressNativeDuplicate = NativeNotificationFilter.shouldSuppress(item)
        let waitForImage = !silent && !suppressNativeDuplicate && item.imageData == nil && Self.expectsImage(packet)
        let token = imageTracker.begin(key, packetId: packet.id, hash: packet.string(for: "payloadHash"), waiting: waitForImage)

        // The phone marks an update that shouldn't alert again (a download's
        // progress, a timer) and the current notifications it sends on
        // request as silent. An update still refreshes its banner, quietly.
        if silent {
            if isUpdate, !suppressNativeDuplicate { updateDeliveredBanner(item) }
            return
        }
        // Keep mirrored WhatsApp items without duplicating native alerts.
        if suppressNativeDuplicate { return }

        if let code = item.code, UserDefaults.standard.bool(forKey: OneTimeCode.autoCopyKey) {
            Self.copyToPasteboard(code)
            TetherLog("[NotificationPlugin] Copied a verification code from \(appName)")
        }

        if waitForImage {
            // Never hold up an alert for a slow/broken image transfer. A late
            // image enriches the in-app list without posting a second banner.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.imageWait) { [weak self] in
                self?.finishWaiting(key, token: token)
            }
        } else {
            post(item)
        }
    }

    static func expectsImage(_ packet: NetworkPacket) -> Bool {
        guard let size = packet.payloadSize, size > 0, size <= NotificationImages.maximumPayloadSize else { return false }
        return packet.payloadPort != nil
    }

    public func handlePayload(connection: DeviceConnection, packet: NetworkPacket, fileURL: URL) {
        guard packet.type == PacketType.notification,
              let deviceId = connection.peerDeviceInfo?.deviceId,
              activeConnections[deviceId] === connection,
              TrustStore.shared.pairedDevice(for: deviceId)?.isNotificationSyncEnabled == true,
              let id = packet.string(for: "id") else { return }
        let key = NotificationImageTracker.Key(deviceId: deviceId, notificationId: id)
        guard let token = imageTracker.token(for: key, packetId: packet.id, hash: packet.string(for: "payloadHash")) else { return }
        // The file is removed when this returns, so it's read here (it is
        // at most 1 MB). Decoding and re-encoding it happens off the main thread.
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= NotificationImages.maximumPayloadSize,
              let data = try? Data(contentsOf: fileURL) else {
            finishWaiting(key, token: token)
            return
        }
        let hash = packet.string(for: "payloadHash")
        let connectionId = ObjectIdentifier(connection)
        Self.imageQueue.async {
            let png = NotificationImages.normalized(data)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeConnections[deviceId].map(ObjectIdentifier.init) == connectionId else { return }
                if let png {
                    self.images.keep(png, deviceId: deviceId, hash: hash)
                    if let index = self.notifications[deviceId]?.firstIndex(where: { $0.id == id }) {
                        self.notifications[deviceId]?[index].imageData = png
                        if let item = self.notifications[deviceId]?[index] { self.rememberGlyph(of: item) }
                    }
                }
                self.finishWaiting(key, token: token)
            }
        }
    }

    private static let imageQueue = DispatchQueue(label: "com.subhashh.tether.notification-decode", qos: .userInitiated)

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

    /// Replaces a banner still in Notification Center with the new text,
    /// without a sound or a new banner. One that was cleared stays cleared.
    private func updateDeliveredBanner(_ item: PhoneNotification) {
        let identifier = Self.identifier(deviceId: item.deviceId, id: item.id)
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            guard delivered.contains(where: { $0.request.identifier == identifier }) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let current = self.notifications[item.deviceId]?.first(where: { $0.id == item.id }) else { return }
                self.post(current, quietly: true)
            }
        }
    }

    private func post(_ item: PhoneNotification, quietly: Bool = false) {
        // Recheck after an image wait: WhatsApp may have launched meanwhile.
        guard !NativeNotificationFilter.shouldSuppress(item) else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title.isEmpty ? item.appName : "\(item.appName): \(item.title)"
        content.body = item.text
        content.sound = quietly ? nil : .default
        if quietly { content.interruptionLevel = .passive }
        // A chat's banners stack together in Notification Center.
        content.threadIdentifier = "\(item.deviceId)|\(item.threadKey)"
        content.categoryIdentifier = Self.category(hasCode: item.code != nil, hasReply: item.replyId != nil)
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
            // The phone has gone since the banner was shown. A typed reply
            // must not vanish without a word.
            if response is UNTextInputNotificationResponse {
                Self.postReplyNotSent(appName: userInfo["appName"] as? String ?? "")
            }
            completionHandler()
            return
        }

        if let textResponse = response as? UNTextInputNotificationResponse,
           let replyId = userInfo["replyId"] as? String, !replyId.isEmpty {
            let replyText = textResponse.userText
            let replyPacket = NetworkPacket(
                type: PacketType.notificationReply,
                body: [
                    "requestReplyId": replyId,
                    "message": replyText
                ]
            )
            connection.send(packet: replyPacket)
            TetherLog("[NotificationPlugin] Sent a notification reply to \(deviceId)")
        } else if response.actionIdentifier == "TETHER_DISMISS_ACTION" {
            if let notifId = userInfo["notifId"] as? String {
                let dismissPacket = NetworkPacket(
                    type: PacketType.notificationRequest,
                    body: ["cancel": notifId]
                )
                connection.send(packet: dismissPacket)
                removeLocally(id: notifId, deviceId: deviceId)
                TetherLog("[NotificationPlugin] Sent dismiss request for \(notifId)")
            }
        }

        completionHandler()
    }

    private static func postReplyNotSent(appName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Reply Not Sent"
        content.body = appName.isEmpty
            ? "The phone isn't connected. Reply again once it's back."
            : "The phone isn't connected. Reply in \(appName) once it's back."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "tether-reply-not-sent", content: content, trigger: nil))
    }

    /// A chat as text for a banner: each message, with its sender's name
    /// before it when the sender changes. The first sender is the title.
    static func plainText(of conversation: [PhoneNotification.ConversationLine], title: String) -> String {
        var previous = title
        var lines: [String] = []
        for line in conversation {
            if !line.sender.isEmpty, line.sender != previous {
                lines.append("\(line.sender): \(line.content)")
                previous = line.sender
            } else {
                lines.append(line.content)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Android 15 hides the content of notifications it thinks are
    /// sensitive (codes, mostly) from apps like KDE Connect.
    static func isRedacted(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Sensitive notification content hidden") == .orderedSame
    }
}
