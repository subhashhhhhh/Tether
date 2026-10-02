//
//  DeviceViewModel.swift
//  Tether
//
//  Native macOS SwiftUI @Observable view model representing a device.
//

import SwiftUI
import Observation
import UserNotifications

public enum DeviceStatus: String, CaseIterable, Sendable {
    case connected = "Connected"
    case available = "Available"
    case offline = "Offline"

    public var systemImageName: String {
        switch self {
        case .connected: return "circle.fill"
        case .available: return "antenna.radiowaves.left.and.right"
        case .offline: return "circle"
        }
    }

    public var color: Color {
        switch self {
        case .connected: return .green
        case .available: return .blue
        case .offline: return .secondary
        }
    }
}

public struct DeliveredNotificationItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let date: Date
    public let appName: String
    public let replyId: String?
    public let deviceId: String

    public init(
        id: String,
        title: String,
        body: String,
        date: Date = Date(),
        appName: String = "Phone",
        replyId: String? = nil,
        deviceId: String = ""
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.date = date
        self.appName = appName
        self.replyId = replyId
        self.deviceId = deviceId
    }
}

@Observable
@MainActor
public final class DeviceViewModel: Identifiable, Hashable {
    public let id: String
    public var name: String
    public var deviceType: DeviceType
    public var status: DeviceStatus
    public var batteryPercent: Int?
    public var isCharging: Bool
    public var networkType: String?
    public var cellularSignalStrength: Int?
    public var volume: Float
    public var isMuted: Bool
    public var nowPlayingTitle: String?
    public var nowPlayingArtist: String?
    public var nowPlayingIsPlaying: Bool
    public var transfers: [TransferItem]
    public var smsThreads: [SMSConversation]
    public var commands: [RemoteCommand]
    public var notifications: [DeliveredNotificationItem]

    // Action handlers injected by TetherAppModel or mocked
    public var onPing: (() -> Void)?
    public var onSendClipboard: (() -> Void)?
    public var onSendFile: ((URL) -> Void)?
    public var onFindPhone: (() -> Void)?
    public var onLockDevice: (() -> Void)?
    public var onPair: (() -> Void)?
    public var onUnpair: (() -> Void)?
    public var onExecuteCommand: ((String) -> Void)?
    public var onSendSMS: ((String, String) -> Void)?
    public var onSetVolume: ((Float) -> Void)?
    public var onMediaAction: ((String) -> Void)?
    public var onDismissNotification: ((String) -> Void)?

    public init(
        id: String,
        name: String,
        deviceType: DeviceType = .phone,
        status: DeviceStatus = .connected,
        batteryPercent: Int? = nil,
        isCharging: Bool = false,
        networkType: String? = nil,
        cellularSignalStrength: Int? = nil,
        volume: Float = 0.5,
        isMuted: Bool = false,
        nowPlayingTitle: String? = nil,
        nowPlayingArtist: String? = nil,
        nowPlayingIsPlaying: Bool = false,
        transfers: [TransferItem] = [],
        smsThreads: [SMSConversation] = [],
        commands: [RemoteCommand] = [],
        notifications: [DeliveredNotificationItem] = []
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.status = status
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.networkType = networkType
        self.cellularSignalStrength = cellularSignalStrength
        self.volume = volume
        self.isMuted = isMuted
        self.nowPlayingTitle = nowPlayingTitle
        self.nowPlayingArtist = nowPlayingArtist
        self.nowPlayingIsPlaying = nowPlayingIsPlaying
        self.transfers = transfers
        self.smsThreads = smsThreads
        self.commands = commands
        self.notifications = notifications
    }

    public static func == (lhs: DeviceViewModel, rhs: DeviceViewModel) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // Actions
    public func ping() { onPing?() }
    public func sendClipboard() { onSendClipboard?() }
    public func sendFile(url: URL) { onSendFile?(url) }
    public func findMyPhone() { onFindPhone?() }
    public func lockDevice() { onLockDevice?() }
    public func pair() { onPair?() }
    public func unpair() { onUnpair?() }
    public func executeCommand(id: String) { onExecuteCommand?(id) }
    public func sendSMS(to address: String, message: String) { onSendSMS?(address, message) }
    public func setVolume(_ val: Float) { onSetVolume?(val) }
    public func playPauseMedia() { onMediaAction?("playPause") }
    public func nextMedia() { onMediaAction?("next") }
    public func previousMedia() { onMediaAction?("previous") }
    public func dismissNotification(id: String) { onDismissNotification?(id) }

    // MARK: - Mocks for Previews

    public static func mockConnectedPhone() -> DeviceViewModel {
        let sampleMessages = [
            SMSMessage(body: "Hey! Did the file transfer arrive?", addresses: ["+15551234567"], date: Date().addingTimeInterval(-180), type: 1, threadId: 101, read: true),
            SMSMessage(body: "Yes, received on MacBook Air.", addresses: ["+15551234567"], date: Date().addingTimeInterval(-60), type: 2, threadId: 101, read: true)
        ]
        let sampleThread = SMSConversation(threadId: 101, addresses: ["Alex Smith"], messages: sampleMessages)

        let sampleTransfer = TransferItem(
            deviceId: "mock_phone",
            deviceName: "Pixel 9 Pro",
            filename: "QuarterlyReport.pdf",
            totalBytes: 15_420_000,
            transferredBytes: 15_420_000,
            direction: .incoming,
            status: .completed,
            progress: 1.0,
            speedBytesPerSec: 0,
            timestamp: Date().addingTimeInterval(-300)
        )

        let sampleNotif = DeliveredNotificationItem(
            id: "notif_1",
            title: "Telegram: Alex Smith",
            body: "Are we meeting at 4 PM today?",
            date: Date().addingTimeInterval(-120),
            appName: "Telegram",
            replyId: "reply_1",
            deviceId: "mock_phone"
        )

        return DeviceViewModel(
            id: "mock_phone",
            name: "Pixel 9 Pro",
            deviceType: .phone,
            status: .connected,
            batteryPercent: 88,
            isCharging: true,
            networkType: "Wi-Fi 6",
            cellularSignalStrength: 4,
            volume: 0.75,
            isMuted: false,
            nowPlayingTitle: "Midnight City",
            nowPlayingArtist: "M83",
            nowPlayingIsPlaying: true,
            transfers: [sampleTransfer],
            smsThreads: [sampleThread],
            commands: RemoteCommand.defaultCommands,
            notifications: [sampleNotif]
        )
    }

    public static func mockConnectedTablet() -> DeviceViewModel {
        DeviceViewModel(
            id: "mock_tablet",
            name: "Galaxy Tab S9",
            deviceType: .tablet,
            status: .connected,
            batteryPercent: 62,
            isCharging: false,
            networkType: "Wi-Fi",
            cellularSignalStrength: nil,
            volume: 0.4
        )
    }

    public static func mockAvailablePhone() -> DeviceViewModel {
        DeviceViewModel(
            id: "mock_available",
            name: "Nothing Phone (2)",
            deviceType: .phone,
            status: .available,
            batteryPercent: nil,
            isCharging: false
        )
    }

    public static func mockOfflinePhone() -> DeviceViewModel {
        DeviceViewModel(
            id: "mock_offline",
            name: "motorola edge 50",
            deviceType: .phone,
            status: .offline,
            batteryPercent: 45,
            isCharging: false
        )
    }
}
