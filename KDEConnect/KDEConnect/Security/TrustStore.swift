//
//  TrustStore.swift
//  KDEConnect
//

import Foundation
import Combine

public final class TrustStore: ObservableObject, @unchecked Sendable {
    public static let shared = TrustStore()

    @Published public private(set) var pairedDevices: [String: PairedDevice] = [:]

    private let userDefaultsKey = "kdeconnect_paired_devices"
    private let queue = DispatchQueue(label: "org.kde.kdeconnect.truststore", attributes: .concurrent)

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
        queue.sync {
            pairedDevices[deviceId] != nil
        }
    }

    public func pairedDevice(for deviceId: String) -> PairedDevice? {
        queue.sync {
            pairedDevices[deviceId]
        }
    }

    public func add(device: PairedDevice) {
        queue.async(flags: .barrier) {
            self.pairedDevices[device.deviceId] = device
            self.saveDevices()
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }

    public func remove(deviceId: String) {
        queue.async(flags: .barrier) {
            self.pairedDevices.removeValue(forKey: deviceId)
            self.saveDevices()
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }

    public func updateLastSeen(deviceId: String) {
        queue.async(flags: .barrier) {
            guard var device = self.pairedDevices[deviceId] else { return }
            device.lastSeenDate = Date()
            self.pairedDevices[deviceId] = device
            self.saveDevices()
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }

    public func updateSettings(deviceId: String, clipboard: Bool, notifications: Bool) {
        queue.async(flags: .barrier) {
            guard var device = self.pairedDevices[deviceId] else { return }
            device.isClipboardSyncEnabled = clipboard
            device.isNotificationSyncEnabled = notifications
            self.pairedDevices[deviceId] = device
            self.saveDevices()
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }
}
