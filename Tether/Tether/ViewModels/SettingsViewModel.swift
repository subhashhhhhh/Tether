//
//  SettingsViewModel.swift
//  Tether
//
//  Native macOS SwiftUI @Observable view model for app settings and preferences.
//

import SwiftUI
import Observation
import ServiceManagement
import UserNotifications
import ApplicationServices

@Observable
@MainActor
public final class SettingsViewModel {
    public static let shared = SettingsViewModel()

    public var deviceName: String = DeviceIdentity.shared.deviceName
    public var deviceId: String = DeviceIdentity.shared.deviceId
    public var certificateFingerprint: String = DeviceIdentity.shared.certificateFingerprint
    public var pairedDevices: [PairedDevice] = []
    public var launchAtLogin: Bool = false
    public var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    public var isAccessibilityTrusted: Bool = false

    private var isMockMode: Bool = false

    public init(isMock: Bool = false) {
        self.isMockMode = isMock
        if !isMock {
            refresh()
        }
    }

    public func refresh() {
        guard !isMockMode else { return }
        self.deviceName = DeviceIdentity.shared.deviceName
        self.deviceId = DeviceIdentity.shared.deviceId
        self.certificateFingerprint = DeviceIdentity.shared.certificateFingerprint
        self.pairedDevices = Array(TrustStore.shared.pairedDevices.values)
        self.isAccessibilityTrusted = AXIsProcessTrusted()
        self.checkLaunchAtLoginStatus()
        self.refreshNotificationStatus()
    }

    public func saveDeviceName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.deviceName = trimmed
        DeviceIdentity.shared.deviceName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "tether_device_name")
    }

    public func unpair(deviceId: String) {
        TetherService.shared.unpair(deviceId: deviceId)
        self.pairedDevices = Array(TrustStore.shared.pairedDevices.values)
    }

    private func checkLaunchAtLoginStatus() {
        let service = SMAppService.mainApp
        self.launchAtLogin = (service.status == .enabled)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
            self.launchAtLogin = (service.status == .enabled)
        } catch {
            TetherLog("[SettingsViewModel] Failed to toggle launch at login: \(error)")
            self.launchAtLogin = (service.status == .enabled)
        }
    }

    public func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationAuthStatus = settings.authorizationStatus
            }
        }
    }

    public func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.refreshNotificationStatus()
            }
        }
    }

    public func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    public func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isAccessibilityTrusted = AXIsProcessTrusted()
        }
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Mocks for Previews

    public static func mock() -> SettingsViewModel {
        let vm = SettingsViewModel(isMock: true)
        vm.deviceName = "subhash’s MacBook Air"
        vm.deviceId = "b0ffaae46842413d997e1da63fcd6f93"
        vm.certificateFingerprint = "7F:1E:AA:32:89:01:BC:DE:45:67:89:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:01:23:45:67:89:AB:CD:EF"
        vm.pairedDevices = [
            PairedDevice(
                deviceId: "mock_phone",
                deviceName: "Pixel 9 Pro",
                deviceType: .phone,
                certificateFingerprint: "94:0A:06:43:72:98:77:70:3B:FC:E5:EC:B4:27:96:C9:F7:C3:6B:1C:50:E5:22:AB:88:00:B3:28:81:F6:D8:76",
                pairedDate: Date().addingTimeInterval(-86400 * 5)
            )
        ]
        vm.launchAtLogin = true
        vm.notificationAuthStatus = .authorized
        vm.isAccessibilityTrusted = true
        return vm
    }

    public static func mockDenied() -> SettingsViewModel {
        let vm = SettingsViewModel.mock()
        vm.notificationAuthStatus = .denied
        vm.isAccessibilityTrusted = false
        return vm
    }
}
