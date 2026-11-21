//
//  PairedDevice.swift
//  Tether
//

import Foundation

struct PairedDevice: Codable, Sendable, Identifiable {
    var id: String { deviceId }
    let deviceId: String
    var deviceName: String
    var deviceType: DeviceType
    var certificateFingerprint: String
    var certificatePEM: String?
    var pairedDate: Date
    var lastSeenDate: Date?
    var isClipboardSyncEnabled: Bool
    var isNotificationSyncEnabled: Bool

    init(
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
