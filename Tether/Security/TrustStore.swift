//
//  TrustStore.swift
//  Tether
//

import Foundation
import Combine

public final class TrustStore: ObservableObject, @unchecked Sendable {
    public static let shared = TrustStore()

    @Published public private(set) var pairedDevices: [String: PairedDevice] = [:]

    private let userDefaultsKey = "tether_paired_devices"
    private let lock = NSLock()

    private init() {
        loadDevices()
    }

    private func loadDevices() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let list = try? JSONDecoder().decode([PairedDevice].self, from: data),
           !list.isEmpty {
            var dict: [String: PairedDevice] = [:]
            for device in list {
                dict[device.deviceId] = device
            }
            self.pairedDevices = dict
            return
        }

        if let oldData = UserDefaults.standard.data(forKey: "kdeconnect_paired_devices"),
           let list = try? JSONDecoder().decode([PairedDevice].self, from: oldData),
           !list.isEmpty {
            var dict: [String: PairedDevice] = [:]
            for device in list {
                dict[device.deviceId] = device
            }
            self.pairedDevices = dict
            saveDevices()
            return
        }

        // Preload user's paired phone so re-pairing is not required
        let knownPhone = PairedDevice(
            deviceId: "5bbcb3e152d34b9597997d39ca4587ce",
            deviceName: "motorola edge 50",
            deviceType: .phone,
            certificateFingerprint: "94:96:86:d6:2b:4f:ee:dd:9c:f8:97:69:a4:f1:b8:40:d5:15:2f:b8:2e:76:ea:f6:08:98:c2:aa:46:af:18:87",
            certificatePEM: nil
        )
        self.pairedDevices = [knownPhone.deviceId: knownPhone]
        saveDevices()
    }

    private func saveDevices() {
        let list = Array(pairedDevices.values)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    public func isTrusted(deviceId: String) -> Bool {
        lock.withLock {
            pairedDevices[deviceId] != nil
        }
    }

    public func pairedDevice(for deviceId: String) -> PairedDevice? {
        lock.withLock {
            pairedDevices[deviceId]
        }
    }

    public func add(device: PairedDevice) {
        lock.withLock {
            self.pairedDevices[device.deviceId] = device
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func remove(deviceId: String) {
        lock.withLock {
            self.pairedDevices.removeValue(forKey: deviceId)
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func updateLastSeen(deviceId: String) {
        lock.withLock {
            guard var device = self.pairedDevices[deviceId] else { return }
            device.lastSeenDate = Date()
            self.pairedDevices[deviceId] = device
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func updateSettings(deviceId: String, clipboard: Bool, notifications: Bool) {
        lock.withLock {
            guard var device = self.pairedDevices[deviceId] else { return }
            device.isClipboardSyncEnabled = clipboard
            device.isNotificationSyncEnabled = notifications
            self.pairedDevices[deviceId] = device
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
}
