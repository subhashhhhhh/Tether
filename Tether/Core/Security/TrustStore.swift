//
//  TrustStore.swift
//  Tether
//

import Foundation
import Combine

final class TrustStore: ObservableObject, @unchecked Sendable {
    static let shared = TrustStore()

    @Published private(set) var pairedDevices: [String: PairedDevice] = [:]

    private let userDefaultsKey = "tether_paired_devices"
    private let lock = NSLock()

    private init() {
        loadDevices()
    }

    /// Build 1.2 shipped with the author's own phone pre-trusted on every install.
    /// It is removed on load so nobody trusts a device they never paired.
    private static let removedPreloadedDeviceIds: Set<String> = ["5bbcb3e152d34b9597997d39ca4587ce"]

    private func loadDevices() {
        let stored = Self.decode(key: userDefaultsKey) ?? Self.decode(key: "kdeconnect_paired_devices") ?? []
        let kept = stored.filter { !Self.removedPreloadedDeviceIds.contains($0.deviceId) }

        self.pairedDevices = Dictionary(kept.map { ($0.deviceId, $0) }, uniquingKeysWith: { _, latest in latest })

        // Persist when migrating from the legacy key or when a preloaded entry was dropped.
        if kept.count != stored.count || UserDefaults.standard.data(forKey: userDefaultsKey) == nil {
            saveDevices()
        }
    }

    private static func decode(key: String) -> [PairedDevice]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            let list = try JSONDecoder().decode([PairedDevice].self, from: data)
            return list.isEmpty ? nil : list
        } catch {
            // Never silently treat unreadable pairings as "none": that would let
            // the next save overwrite them. Keep the raw bytes for recovery.
            TetherLog("[TrustStore] Could not read \(key): \(error)")
            UserDefaults.standard.set(data, forKey: "\(key)_unreadable_backup")
            return nil
        }
    }

    private func saveDevices() {
        let list = Array(pairedDevices.values)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    func isTrusted(deviceId: String) -> Bool {
        lock.withLock {
            pairedDevices[deviceId] != nil
        }
    }

    func pairedDevice(for deviceId: String) -> PairedDevice? {
        lock.withLock {
            pairedDevices[deviceId]
        }
    }

    func add(device: PairedDevice) {
        lock.withLock {
            self.pairedDevices[device.deviceId] = device
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    /// Forgets a paired device. `reason` is logged so a lost pairing can always be traced.
    func remove(deviceId: String, reason: String) {
        lock.withLock {
            let name = self.pairedDevices[deviceId]?.deviceName ?? "unknown"
            TetherLog("[TrustStore] Removing \(name) (\(deviceId)): \(reason)")
            self.pairedDevices.removeValue(forKey: deviceId)
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    func updateLastSeen(deviceId: String) {
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

    func updateSetting(deviceId: String, _ setting: WritableKeyPath<PairedDevice, Bool>, to value: Bool) {
        lock.withLock {
            guard var device = self.pairedDevices[deviceId] else { return }
            device[keyPath: setting] = value
            self.pairedDevices[deviceId] = device
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
}
