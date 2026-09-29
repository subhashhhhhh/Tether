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
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let list = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            return
        }
        var dict: [String: PairedDevice] = [:]
        for device in list {
            dict[device.deviceId] = device
        }
        self.pairedDevices = dict
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
