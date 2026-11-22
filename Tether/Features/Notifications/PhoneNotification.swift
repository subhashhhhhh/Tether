//
//  PhoneNotification.swift
//  Tether
//
//  A notification showing on the phone, mirrored here.
//

import Foundation

/// A notification currently showing on the phone, mirrored for the in-app list.
struct PhoneNotification: Identifiable, Hashable, Sendable {
    let id: String
    let deviceId: String
    let appName: String
    let title: String
    let text: String
    let date: Date
    /// Present when the phone accepts an inline reply (messaging apps).
    let replyId: String?
    let isDismissable: Bool
    /// The notification's own buttons on the phone ("Mark as read", "Mute").
    var actions: [String] = []
    /// A chat notification's recent messages, oldest first.
    var conversation: [ConversationLine] = []
    /// A group chat's name; nil for a one-to-one chat.
    var groupName: String? = nil
    /// Android 15 replaced the text with "Sensitive notification content hidden".
    var isRedacted = false

    struct ConversationLine: Hashable, Sendable {
        let sender: String
        let content: String
    }

    /// The Android package, from the notification's key
    /// ("user|package|id|tag|uid"); nil for a key in another form.
    var packageName: String? {
        let fields = id.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count >= 5, Int(fields[0]) != nil, !fields[1].isEmpty else { return nil }
        return String(fields[1])
    }

    /// What an app's glyph is stored under: its package, so two apps with
    /// the same name don't share one, else its name.
    var glyphKey: String { packageName ?? appName }

    /// From Android itself, which uses a different icon for each kind of
    /// notification (battery, Wi-Fi, USB), so its icon belongs to the
    /// notification, not to an app.
    var isFromSystem: Bool {
        if let packageName { return packageName == "android" || packageName == "com.android.systemui" }
        return appName == "Android System" || appName == "System UI"
    }

    /// Which chat or thread it belongs to, for grouping banners.
    var threadKey: String { "\(glyphKey)|\(groupName ?? title)" }
    /// A one-time verification code found in the title or text.
    var code: String? = nil
    /// Artwork supplied by the phone; it may be a contact photo rather than an app logo.
    var imageData: Data? = nil {
        didSet { imageIsGlyph = imageData.map(NotificationImages.isGlyph) ?? false }
    }
    /// The artwork is the app's flat status-bar icon rather than a picture.
    private(set) var imageIsGlyph = false

    init(id: String, deviceId: String, appName: String, title: String, text: String, date: Date,
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
