//
//  PairedDevice.swift
//  Tether
//

import Foundation

public struct PairedDevice: Codable, Sendable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public var deviceName: String
    public var deviceType: DeviceType
    public var certificateFingerprint: String
    public var certificatePEM: String?
    public var pairedDate: Date
    public var lastSeenDate: Date?
    public var isClipboardSyncEnabled: Bool
    public var isNotificationSyncEnabled: Bool

    public init(
        deviceId: String,
        deviceName: String,
        deviceType: DeviceType,
        certificateFingerprint: String,
        certificatePEM: String? = nil,
        pairedDate: Date = Date(),
        lastSeenDate: Date? = nil,
        isClipboardSyncEnabled: Bool = true,
        isNotificationSyncEnabled: Bool = true
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.certificateFingerprint = certificateFingerprint
        self.certificatePEM = certificatePEM
        self.pairedDate = pairedDate
        self.lastSeenDate = lastSeenDate
        self.isClipboardSyncEnabled = isClipboardSyncEnabled
        self.isNotificationSyncEnabled = isNotificationSyncEnabled
    }
}
