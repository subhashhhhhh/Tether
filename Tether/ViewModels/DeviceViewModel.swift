//
//  DeviceViewModel.swift
//  Tether
//
//  Observable view state for one device. Instances are cached by device ID in
//  TetherAppModel and updated in place, so view state survives model refreshes.
//

import SwiftUI
import AppKit
import Observation

public enum DeviceStatus: String, CaseIterable, Sendable {
    case connected = "Connected"
    case available = "Nearby"
    case offline = "Offline"
}

@Observable
@MainActor
public final class DeviceViewModel: Identifiable, Hashable {
    public let id: String
    public var name: String
    public var deviceType: DeviceType
    public var status: DeviceStatus
    public var lastSeen: Date?

    public var batteryPercent: Int?
    public var isCharging: Bool
    public var networkType: String?
    public var cellularSignalStrength: Int?
    /// The phone's SIMs, when it has reported them.
    public var sims: [PhoneSIM] = []

    public var volume: Float
    public var isMuted: Bool
    public var nowPlayingTitle: String?
    public var nowPlayingArtist: String?
    public var nowPlayingAlbum: String?
    public var nowPlayingIsPlaying: Bool
    /// The phone's media apps, and the one shown.
    public var mediaPlayers: [String] = []
    public var currentMediaPlayer: String?
    /// Decoded once when the bytes change, never in a view body.
    public private(set) var albumArt: NSImage?
    @ObservationIgnored private var albumArtData: Data?

    public var transfers: [TransferItem]
    public var smsThreads: [SMSConversation]
    /// The phone's contacts, for names and photos instead of numbers.
    var contacts = ContactBook()
    public var commands: [RemoteCommand]
    public var notifications: [PhoneNotification]
    /// The last few things the device sent to this Mac's clipboard, newest first.
    public var receivedClipboard: [String] = []
    /// Each app's status-bar glyph from the phone, by app name.
    public var appGlyphs: [String: Data] = [:]
    /// Bumped by the toolbar's New Message button; the Messages pane starts a draft.
    public var composeRequests = 0

    /// True between asking a nearby device to pair and it answering.
    public var isAwaitingPairing = false
    /// Whether the device accepts lock requests. KDE Connect for Android has no
    /// lock feature, so this is only true for desktops running KDE Connect.
    public var canLock = false
    /// Whether there's anything to set the volume of: on Android, a media app
    /// with an active session.
    public var canSetVolume = false
    /// Connected through Tailscale rather than the local network.
    public var isViaTailscale = false

    // Action handlers injected by TetherAppModel or mocked
    public var onPing: (() -> Void)?
    public var onSendClipboard: (() -> Void)?
    public var onCopyReceivedClipboard: ((String) -> Void)?
    public var onCancelTransfer: ((UUID) -> Void)?
    public var onSendFiles: (([URL]) -> Void)?
    public var onFindPhone: (() -> Void)?
    public var onLockDevice: (() -> Void)?
    public var onPair: (() -> Void)?
    public var onUnpair: (() -> Void)?
    public var onExecuteCommand: ((String) -> Void)?
    public var onSaveCommand: ((RemoteCommand) -> Void)?
    public var onDeleteCommand: ((String) -> Void)?
    public var onSendSMS: (([String], String, Int64?, Int64?) -> Void)?
    public var onRefreshMessages: (() -> Void)?
    public var onOpenThread: ((Int64) -> Void)?
    public var onOpenAttachment: ((SMSAttachment) -> Void)?
    public var onLoadEarlierMessages: ((Int64) -> Void)?
    public var onSetVolume: ((Float) -> Void)?
    public var onMediaAction: ((String) -> Void)?
    public var onChooseMediaPlayer: ((String?) -> Void)?
    public var onReplyToNotification: ((PhoneNotification, String) -> Void)?
    public var onDismissNotification: ((PhoneNotification) -> Void)?
    public var onNotificationAction: ((PhoneNotification, String) -> Void)?

    public init(
        id: String,
        name: String,
        deviceType: DeviceType = .phone,
        status: DeviceStatus = .connected,
        lastSeen: Date? = nil,
        batteryPercent: Int? = nil,
        isCharging: Bool = false,
        networkType: String? = nil,
        cellularSignalStrength: Int? = nil,
        volume: Float = 0.5,
        isMuted: Bool = false,
        nowPlayingTitle: String? = nil,
        nowPlayingArtist: String? = nil,
        nowPlayingAlbum: String? = nil,
        nowPlayingIsPlaying: Bool = false,
        transfers: [TransferItem] = [],
        smsThreads: [SMSConversation] = [],
        commands: [RemoteCommand] = [],
        notifications: [PhoneNotification] = []
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.status = status
        self.lastSeen = lastSeen
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.networkType = networkType
        self.cellularSignalStrength = cellularSignalStrength
        self.volume = volume
        self.isMuted = isMuted
        self.nowPlayingTitle = nowPlayingTitle
        self.nowPlayingArtist = nowPlayingArtist
        self.nowPlayingAlbum = nowPlayingAlbum
        self.nowPlayingIsPlaying = nowPlayingIsPlaying
        self.transfers = transfers
        self.smsThreads = smsThreads
        self.commands = commands
        self.notifications = notifications
    }

    public nonisolated static func == (lhs: DeviceViewModel, rhs: DeviceViewModel) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public var isConnected: Bool { status == .connected }

    func setAlbumArt(_ data: Data?) {
        guard data != albumArtData else { return }
        albumArtData = data
        albumArt = data.flatMap(NSImage.init(data:))
    }

    public var hasNowPlaying: Bool {
        !(nowPlayingTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var activeTransferCount: Int {
        transfers.filter { $0.status == .transferring }.count
    }

    /// One-line status used under the device name in lists.
    public var statusLine: String {
        switch status {
        case .connected:
            var parts = ["Connected"]
            if let batteryPercent { parts.append("\(batteryPercent)%") }
            return parts.joined(separator: " · ")
        case .available:
            return isAwaitingPairing ? "Waiting for phone…" : "Ready to pair"
        case .offline:
            if let lastSeen {
                return "Last seen \(lastSeen.formatted(.relative(presentation: .named)))"
            }
            return "Not nearby"
        }
    }

    // Actions
    public func ping() { onPing?() }
    public func sendClipboard() { onSendClipboard?() }
    public func copyReceivedClipboard(_ text: String) { onCopyReceivedClipboard?(text) }
    public func cancelTransfer(_ id: UUID) { onCancelTransfer?(id) }
    public func sendFiles(_ urls: [URL]) { onSendFiles?(urls) }
    public func findMyPhone() { onFindPhone?() }
    public func lockDevice() { onLockDevice?() }
    public func pair() {
        isAwaitingPairing = true
        onPair?()
    }
    public func unpair() { onUnpair?() }
    public func executeCommand(id: String) { onExecuteCommand?(id) }
    public func saveCommand(_ command: RemoteCommand) { onSaveCommand?(command) }
    public func deleteCommand(id: String) { onDeleteCommand?(id) }
    public func sendSMS(to addresses: [String], message: String, threadId: Int64?, subId: Int64? = nil) {
        onSendSMS?(addresses, message, threadId, subId)
    }

    /// The SIM to offer for a conversation: the one it last used, else the one
    /// the latest sent message went out on, else the first.
    func defaultSIM(for thread: SMSConversation?) -> Int64? {
        let ids = Set(sims.map(\.id))
        if let used = thread?.messages.last(where: { $0.subId.map(ids.contains) ?? false })?.subId {
            return used
        }
        let lastSent = smsThreads
            .flatMap(\.messages)
            .filter { $0.isOutgoing && ($0.subId.map(ids.contains) ?? false) }
            .max { $0.date < $1.date }
        return lastSent?.subId ?? sims.first?.id
    }
    /// The thread's people by name where the phone's contacts know them. A
    /// business chat is named for the business, as the phone shows it.
    func title(for thread: SMSConversation) -> String {
        guard !thread.addresses.isEmpty else { return thread.title }
        if let business = thread.addresses.lazy.compactMap(Self.businessName).first { return business }
        return Self.unique(thread.addresses).map { contacts.contact(for: $0)?.name ?? $0 }.joined(separator: ", ")
    }

    /// A thread's addresses once each, in order. The phone can list one twice.
    static func unique(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.filter { seen.insert($0).inserted }
    }

    /// The name in an RCS business address: "bluedart_yftwsowo_agent@rbm.goog"
    /// is Bluedart. Nil for anything else.
    static func businessName(_ address: String) -> String? {
        guard address.hasSuffix("@rbm.goog"), let local = address.split(separator: "@").first else { return nil }
        var parts = local.split(separator: "_").map(String.init)
        if parts.last == "agent" { parts.removeLast() }
        // What's left ends in a random token; the words before it are the name.
        if parts.count > 1 { parts.removeLast() }
        let name = parts.joined(separator: " ")
        return name.isEmpty ? nil : name.capitalized
    }

    /// Whether a thread is from a business's sender ID rather than a person:
    /// one address that isn't in the contacts and isn't a phone number.
    func isSenderID(_ thread: SMSConversation) -> Bool {
        if thread.addresses.contains(where: { Self.businessName($0) != nil }) { return true }
        guard thread.addresses.count == 1, let address = thread.addresses.first,
              contacts.contact(for: address) == nil else { return false }
        // "AD-HDFCBK-S", "AX-INDANE-S": letters, all capitals, no spaces. A
        // name the phone sent in place of a number ("Mom") is still a person.
        return address.contains(where: \.isLetter)
            && !address.contains(where: { $0.isLowercase || $0.isWhitespace })
    }

    /// The contact photo for a one-to-one thread.
    func photo(for thread: SMSConversation) -> Data? {
        guard thread.addresses.count == 1, let address = thread.addresses.first else { return nil }
        return contacts.contact(for: address)?.photo
    }

    public func refreshMessages() { onRefreshMessages?() }
    public func openThread(_ threadId: Int64) { onOpenThread?(threadId) }
    public func openAttachment(_ attachment: SMSAttachment) { onOpenAttachment?(attachment) }
    public func loadEarlierMessages(_ threadId: Int64) { onLoadEarlierMessages?(threadId) }
    public func setVolume(_ val: Float) { onSetVolume?(val) }
    public func playPauseMedia() { onMediaAction?("PlayPause") }
    public func chooseMediaPlayer(_ player: String) { onChooseMediaPlayer?(player) }
    public func nextMedia() { onMediaAction?("Next") }
    public func previousMedia() { onMediaAction?("Previous") }
    public func reply(to notification: PhoneNotification, text: String) { onReplyToNotification?(notification, text) }
    public func dismiss(_ notification: PhoneNotification) { onDismissNotification?(notification) }
    /// The app's glyph for a notification: by package, else by the app
    /// name it was saved under before.
    public func glyph(for notification: PhoneNotification) -> Data? {
        // Android's own icons differ per notification; there's no app icon.
        guard !notification.isFromSystem else { return nil }
        return appGlyphs[notification.glyphKey] ?? appGlyphs[notification.appName]
    }

    public func perform(_ action: String, on notification: PhoneNotification) { onNotificationAction?(notification, action) }
}

#if DEBUG
// MARK: - Mocks for Previews

extension DeviceViewModel {
    public static func mockConnectedPhone() -> DeviceViewModel {
        let now = Date()
        let earlier = (0..<12).map { index in
            SMSMessage(body: ["Morning!", "Did you see the agenda?", "Yes, looks fine", "Room 4 or 6?", "6, the one with the screen",
                              "Got it", "Bringing the adapter", "Thanks", "Lunch after?", "Sure", "The usual place", "Perfect"][index],
                       addresses: ["Alex Rivera"], date: now.addingTimeInterval(-3600 * 30 + Double(index) * 120),
                       type: index % 2 == 0 ? 1 : 2, threadId: 101, read: true)
        }
        let alex = SMSConversation(threadId: 101, addresses: ["Alex Rivera"], messages: earlier + [
            SMSMessage(body: "Did the slides come through?", addresses: ["Alex Rivera"], date: now.addingTimeInterval(-3600 * 26), type: 1, threadId: 101, read: true),
            SMSMessage(body: "Yep, opening them now", addresses: ["Alex Rivera"], date: now.addingTimeInterval(-3600 * 25), type: 2, threadId: 101, read: true),
            SMSMessage(body: "Are we still on for 4?", addresses: ["Alex Rivera"], date: now.addingTimeInterval(-240), type: 1, threadId: 101, read: false),
            SMSMessage(body: "Running ten minutes late, save me a seat", addresses: ["Alex Rivera"], date: now.addingTimeInterval(-60), type: 2, threadId: 101, read: true)
        ])
        let mom = SMSConversation(threadId: 102, addresses: ["Mom"], messages: [
            SMSMessage(body: "Call me when you land ✈️", addresses: ["Mom"], date: now.addingTimeInterval(-7200), type: 1, threadId: 102, read: true)
        ])
        let sam = SMSConversation(threadId: 103, addresses: ["Sam Chen"], messages: [
            SMSMessage(body: "Sending you the photos from Saturday", addresses: ["Sam Chen"], date: now.addingTimeInterval(-3600 * 30), type: 1, threadId: 103, read: true)
        ])

        let phone = DeviceViewModel(
            id: "mock_phone",
            name: "Pixel 9 Pro",
            deviceType: .phone,
            status: .connected,
            batteryPercent: 82,
            isCharging: true,
            networkType: "5G",
            cellularSignalStrength: 3,
            volume: 0.6,
            nowPlayingTitle: "Midnight City",
            nowPlayingArtist: "M83",
            nowPlayingAlbum: "Hurry Up, We're Dreaming",
            nowPlayingIsPlaying: true,
            transfers: [
                TransferItem(deviceId: "mock_phone", deviceName: "Pixel 9 Pro", filename: "IMG_2041.HEIC", totalBytes: 3_420_000, transferredBytes: 2_100_000, direction: .incoming, status: .transferring, progress: 0.61),
                TransferItem(deviceId: "mock_phone", deviceName: "Pixel 9 Pro", filename: "Quarterly Report.pdf", totalBytes: 15_420_000, transferredBytes: 15_420_000, direction: .outgoing, status: .completed, progress: 1, timestamp: now.addingTimeInterval(-900)),
                TransferItem(deviceId: "mock_phone", deviceName: "Pixel 9 Pro", filename: "Boarding Pass.pdf", totalBytes: 820_000, transferredBytes: 820_000, direction: .incoming, status: .completed, progress: 1, timestamp: now.addingTimeInterval(-4000))
            ],
            smsThreads: [alex, mom, sam],
            commands: RemoteCommand.defaultCommands,
            notifications: [
                PhoneNotification(id: "n0", deviceId: "mock_phone", appName: "Messages", title: "Northwind", text: "739104 is your Northwind sign-in code. It expires in 10 minutes.", date: now.addingTimeInterval(-30), replyId: nil, isDismissable: true, code: "739104"),
                PhoneNotification(id: "n1", deviceId: "mock_phone", appName: "WhatsApp", title: "Alex Smith", text: "Are we meeting at 4 PM today?", date: now.addingTimeInterval(-120), replyId: "r1", isDismissable: true, actions: ["Mark as read", "Mute"]),
                PhoneNotification(id: "n2", deviceId: "mock_phone", appName: "Gmail", title: "Your order has shipped", text: "Arriving Thursday. Track your package for live updates.", date: now.addingTimeInterval(-1800), replyId: nil, isDismissable: true)
            ]
        )
        phone.canSetVolume = true
        phone.sims = [PhoneSIM(id: 1, number: 1, networkType: "5G"), PhoneSIM(id: 2, number: 2, networkType: "4G")]
        phone.receivedClipboard = ["Gate B14, boarding 18:40", "https://maps.example.com/trailhead"]
        return phone
    }

    public static func mockConnectedTablet() -> DeviceViewModel {
        DeviceViewModel(id: "mock_tablet", name: "Galaxy Tab S9", deviceType: .tablet, status: .connected, batteryPercent: 47, networkType: "Wi-Fi")
    }

    public static func mockAvailablePhone() -> DeviceViewModel {
        DeviceViewModel(id: "mock_available", name: "Nothing Phone (2)", deviceType: .phone, status: .available)
    }

    public static func mockOfflinePhone() -> DeviceViewModel {
        DeviceViewModel(id: "mock_offline", name: "OnePlus 12", deviceType: .phone, status: .offline, lastSeen: Date().addingTimeInterval(-3600 * 5))
    }
}
#endif
