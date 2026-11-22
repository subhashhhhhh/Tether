//
//  SettingsViewModel.swift
//  Tether
//
//  Native macOS SwiftUI @Observable view model for app settings and preferences.
//

import SwiftUI
import Combine
import Observation
import ServiceManagement
import UserNotifications
import ApplicationServices

@Observable
@MainActor
final class SettingsViewModel {
    static let shared = SettingsViewModel()

    var deviceName: String = DeviceIdentity.shared.deviceName
    var deviceId: String = DeviceIdentity.shared.deviceId
    var certificateFingerprint: String = DeviceIdentity.shared.certificateFingerprint
    var pairedDevices: [PairedDevice] = []
    var launchAtLogin: Bool = false
    var tailscaleStatus: TailscaleStatus = .notInstalled
    var isTailscaleDiscoveryEnabled: Bool = TailscaleDiscovery.isEnabled {
        didSet {
            guard !isMockMode, oldValue != isTailscaleDiscoveryEnabled else { return }
            UserDefaults.standard.set(isTailscaleDiscoveryEnabled, forKey: TailscaleDiscovery.enabledKey)
            TetherService.shared.refreshTailscale()
        }
    }
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    private var isMockMode: Bool = false

    init(isMock: Bool = false) {
        self.isMockMode = isMock
        if !isMock {
            refresh()
            TetherService.shared.$tailscaleStatus
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.tailscaleStatus = $0 }
                .store(in: &cancellables)
        }
    }

    func refresh() {
        guard !isMockMode else { return }
        self.deviceName = DeviceIdentity.shared.deviceName
        self.deviceId = DeviceIdentity.shared.deviceId
        self.certificateFingerprint = DeviceIdentity.shared.certificateFingerprint
        reloadPairedDevices()
        self.checkLaunchAtLoginStatus()
    }

    func saveDeviceName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.deviceName = trimmed
        DeviceIdentity.shared.deviceName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "tether_device_name")
        TetherService.shared.refreshAdvertisement()
    }

    func unpair(deviceId: String) {
        TetherService.shared.unpair(deviceId: deviceId)
        reloadPairedDevices()
    }

    func binding(_ setting: WritableKeyPath<PairedDevice, Bool>, for device: PairedDevice) -> Binding<Bool> {
        Binding(
            get: { device[keyPath: setting] },
            set: { value in
                guard !self.isMockMode else { return }
                TrustStore.shared.updateSetting(deviceId: device.deviceId, setting, to: value)
                self.reloadPairedDevices()
            }
        )
    }

    /// Port the TCP listener actually bound, which peers dial back on.
    var listeningPort: Int { DeviceIdentity.shared.advertisedTCPPort }

    private func reloadPairedDevices() {
        self.pairedDevices = TrustStore.shared.pairedDevices.values
            .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
    }

    private func checkLaunchAtLoginStatus() {
        let service = SMAppService.mainApp
        self.launchAtLogin = (service.status == .enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
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

    // MARK: - Mocks for Previews

    #if DEBUG
    static func mock() -> SettingsViewModel {
        let vm = SettingsViewModel(isMock: true)
        vm.deviceName = "MacBook Air"
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
        vm.tailscaleStatus = .running(selfIP: "100.101.42.7", phones: [
            TailscalePeer(name: "Pixel 9 Pro", ip: "100.88.17.53", os: "android")
        ])
        return vm
    }
    #endif
}
