//
//  BatteryPlugin.swift
//  Tether
//

import Foundation
import Combine

public struct DeviceBatteryInfo: Sendable {
    public let currentCharge: Int // 0 - 100
    public let isCharging: Bool
    public let thresholdBatteryEvent: Int?

    public init(currentCharge: Int, isCharging: Bool, thresholdBatteryEvent: Int? = nil) {
        self.currentCharge = currentCharge
        self.isCharging = isCharging
        self.thresholdBatteryEvent = thresholdBatteryEvent
    }
}

public final class BatteryPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {
    public let supportedPacketTypes = ["kdeconnect.battery"]

    @Published public private(set) var deviceBatteries: [String: DeviceBatteryInfo] = [:]

    public init() {}

    public func onConnected(connection: DeviceConnection) {}
    public func onDisconnected(connection: DeviceConnection) {
        if let id = connection.peerDeviceInfo?.deviceId {
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
        let threshold = packet.int(for: "thresholdBatteryEvent", default: 0)

        guard charge >= 0 else { return }

        let info = DeviceBatteryInfo(
            currentCharge: charge,
            isCharging: isCharging,
            thresholdBatteryEvent: threshold
        )

        DispatchQueue.main.async {
            self.deviceBatteries[deviceId] = info
        }
    }
}
