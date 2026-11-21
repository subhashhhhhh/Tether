//
//  BatteryPlugin.swift
//  Tether
//

import Foundation
import Combine

public struct DeviceBatteryInfo: Sendable, Equatable {
    public let currentCharge: Int // 0 - 100
    public let isCharging: Bool
    public let thresholdBatteryEvent: Int?

    public init(currentCharge: Int, isCharging: Bool, thresholdBatteryEvent: Int? = nil) {
        self.currentCharge = currentCharge
        self.isCharging = isCharging
        self.thresholdBatteryEvent = thresholdBatteryEvent
    }
}

/// The phone's battery for the Mac, and this Mac's battery for the phone.
public final class BatteryPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {
    public let supportedPacketTypes = ["kdeconnect.battery"]

    @Published public private(set) var deviceBatteries: [String: DeviceBatteryInfo] = [:]

    private let lock = NSLock()
    private var connections: [String: DeviceConnection] = [:]
    private var lastSent: MacBatteryStatus?

    public init() {
        Task { @MainActor in
            MacBattery.observe { [weak self] in self?.reportMacBattery() }
        }
    }

    public func onConnected(connection: DeviceConnection) {
        if let id = connection.peerDeviceInfo?.deviceId {
            lock.withLock { connections[id] = connection }
        }
        // Like desktop KDE Connect: the current charge as soon as the phone connects.
        if let packet = Self.packet(MacBattery.status()) { connection.send(packet: packet) }
        // The phone reports its battery when it changes, not when it
        // reconnects, so until it does, show what it last said.
        if let id = connection.peerDeviceInfo?.deviceId, let saved = Self.saved(for: id) {
            DispatchQueue.main.async {
                if self.deviceBatteries[id] == nil { self.deviceBatteries[id] = saved }
            }
        }
    }

    private static func key(_ deviceId: String) -> String { "tether_battery_\(deviceId)" }

    private static func saved(for deviceId: String) -> DeviceBatteryInfo? {
        guard let values = UserDefaults.standard.dictionary(forKey: key(deviceId)),
              let charge = values["charge"] as? Int, (0...100).contains(charge) else { return nil }
        return DeviceBatteryInfo(currentCharge: charge, isCharging: values["charging"] as? Bool ?? false)
    }

    public func onDisconnected(connection: DeviceConnection) {
        if let id = connection.peerDeviceInfo?.deviceId {
            lock.withLock { if connections[id] === connection { connections[id] = nil } }
            DispatchQueue.main.async {
                if !TetherService.shared.isDeviceConnected(deviceId: id) {
                    self.deviceBatteries.removeValue(forKey: id)
                }
            }
        }
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.battery",
              let deviceId = connection.peerDeviceInfo?.deviceId else {
            return
        }

        let charge = packet.int(for: "currentCharge", default: -1)
        let isCharging = packet.bool(for: "isCharging", default: false)
        let threshold = packet.int(for: "thresholdEvent", default: 0)

        guard charge >= 0 else { return }

        let info = DeviceBatteryInfo(
            currentCharge: charge,
            isCharging: isCharging,
            thresholdBatteryEvent: threshold
        )

        UserDefaults.standard.set(["charge": charge, "charging": isCharging], forKey: Self.key(deviceId))
        DispatchQueue.main.async {
            if self.deviceBatteries[deviceId] != info { self.deviceBatteries[deviceId] = info }
        }
    }

    // MARK: - This Mac

    /// Tells every connected phone about this Mac's battery, when it changed.
    private func reportMacBattery() {
        guard let status = MacBattery.status() else { return }
        let targets: [DeviceConnection]? = lock.withLock {
            guard status != lastSent else { return nil }
            lastSent = status
            return Array(connections.values)
        }
        guard let targets, let packet = Self.packet(status) else { return }
        TetherLog("[Battery] This Mac: \(status.charge)%\(status.isCharging ? ", plugged in" : "")")
        for connection in targets { connection.send(packet: packet) }
    }

    /// Nothing on a Mac without a battery, as desktop KDE Connect does.
    private static func packet(_ status: MacBatteryStatus?) -> NetworkPacket? {
        guard let status else { return nil }
        return NetworkPacket(type: "kdeconnect.battery", body: [
            "currentCharge": status.charge,
            "isCharging": status.isCharging,
            "batteryQuantity": status.batteryCount,
            "thresholdEvent": status.isLow ? 1 : 0,
        ])
    }
}
