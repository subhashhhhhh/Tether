//
//  ConnectivityReportPlugin.swift
//  Tether
//

import Foundation
import Combine

/// Cellular network type and signal strength reported by the phone.
public struct SignalStrength: Sendable, Equatable {
    public let networkType: String
    /// 0...4, as reported by the peer.
    public let strength: Int

    public init(networkType: String, strength: Int) {
        self.networkType = networkType
        self.strength = strength
    }

    /// Short label for the menu bar, e.g. "LTE" or "5G".
    public var shortLabel: String {
        networkType.isEmpty || networkType == "Unknown" ? "Cellular" : networkType
    }
}

/// Tracks the phone's cellular connectivity.
///
/// The peer sends `kdeconnect.connectivity_report` with a `signalStrengths` object
/// keyed by SIM subscription id, each holding `networkType` and `signalStrength`.
public final class ConnectivityReportPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {

    public let supportedPacketTypes = ["kdeconnect.connectivity_report"]

    /// Reported signal per device, keyed by device id. A device can have several
    /// subscriptions (dual SIM), so the value is the strongest one.
    @Published public private(set) var signalStrength: [String: SignalStrength] = [:]

    public init() {}

    public func onConnected(connection: DeviceConnection) {}

    public func onDisconnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        signalStrength.removeValue(forKey: deviceId)
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.connectivity_report",
              let deviceId = connection.peerDeviceInfo?.deviceId,
              let strengths = packet.object(for: "signalStrengths") else { return }

        let parsed = strengths.values.compactMap { entry -> SignalStrength? in
            guard let entry = entry as? [String: Any] else { return nil }
            return SignalStrength(
                networkType: entry["networkType"] as? String ?? "Unknown",
                strength: entry["signalStrength"] as? Int ?? 0
            )
        }

        // Prefer whichever subscription has the best signal.
        signalStrength[deviceId] = parsed.max { $0.strength < $1.strength }
    }
}
