//
//  ConnectivityReportPlugin.swift
//  Tether
//

import Foundation
import Combine

/// Cellular network type and signal strength reported by the phone.
struct SignalStrength: Sendable, Equatable {
    let networkType: String
    /// 0...4, as reported by the peer.
    let strength: Int

    init(networkType: String, strength: Int) {
        self.networkType = networkType
        self.strength = strength
    }

    /// Short label for the menu bar, e.g. "LTE" or "5G".
    var shortLabel: String {
        networkType.isEmpty || networkType == "Unknown" ? "Cellular" : networkType
    }
}

/// Tracks the phone's cellular connectivity.
///
/// The peer sends `kdeconnect.connectivity_report` with a `signalStrengths` object
/// keyed by SIM subscription id, each holding `networkType` and `signalStrength`.
final class ConnectivityReportPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {

    let supportedPacketTypes = [PacketType.connectivityReport]

    /// Reported signal per device, keyed by device id. A device can have several
    /// subscriptions (dual SIM), so the value is the strongest one.
    @Published private(set) var signalStrength: [String: SignalStrength] = [:]
    /// Each SIM's signal per device, keyed by subscription id.
    @Published private(set) var subscriptions: [String: [Int64: SignalStrength]] = [:]

    init() {}

    func onConnected(connection: DeviceConnection) {}

    /// Its state belongs to the device, not the connection, and is kept.
    func onConnectionReplaced(old: DeviceConnection, new: DeviceConnection) {}

    func onDisconnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        signalStrength.removeValue(forKey: deviceId)
        subscriptions.removeValue(forKey: deviceId)
    }

    func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == PacketType.connectivityReport,
              let deviceId = connection.peerDeviceInfo?.deviceId,
              let strengths = packet.object(for: "signalStrengths") else { return }

        var parsed: [Int64: SignalStrength] = [:]
        for (subId, entry) in strengths {
            guard let subId = Int64(subId), let entry = entry as? [String: Any] else { continue }
            parsed[subId] = SignalStrength(
                networkType: entry["networkType"] as? String ?? "Unknown",
                strength: entry["signalStrength"] as? Int ?? 0
            )
        }

        // Prefer whichever subscription has the best signal.
        // Only on change: every write here makes the window recompute.
        let best = parsed.values.max { $0.strength < $1.strength }
        if signalStrength[deviceId] != best { signalStrength[deviceId] = best }
        if subscriptions[deviceId] != parsed { subscriptions[deviceId] = parsed }
    }
}
