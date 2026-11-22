//
//  LockDevicePlugin.swift
//  Tether
//

import Foundation
import Combine

/// Locks the phone remotely and tracks the reported lock state.
///
/// `kdeconnect.lock.request` asks the peer to lock itself (`setLocked: true`) or
/// to report its current state (`requestLocked: true`). The peer answers with
/// `kdeconnect.lock` carrying `isLocked` and, for a state query, `lockResult`.
final class LockDevicePlugin: ObservableObject, TetherPlugin, @unchecked Sendable {

    let supportedPacketTypes = [PacketType.lock]

    /// Last reported lock state per device id.
    @Published private(set) var isLocked: [String: Bool] = [:]

    init() {}

    func onConnected(connection: DeviceConnection) {}

    /// Its state belongs to the device, not the connection, and is kept.
    func onConnectionReplaced(old: DeviceConnection, new: DeviceConnection) {}

    func onDisconnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        isLocked.removeValue(forKey: deviceId)
    }

    func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == PacketType.lock,
              let deviceId = connection.peerDeviceInfo?.deviceId else { return }

        isLocked[deviceId] = packet.bool(for: "isLocked", default: false)
    }

    /// Asks the peer to lock itself.
    func lock(connection: DeviceConnection) {
        let packet = NetworkPacket(type: PacketType.lockRequest, body: ["setLocked": true])
        connection.send(packet: packet)
        TetherLog("[LockDevicePlugin] Sent lock request")
    }

    /// Asks the peer to report its current lock state.
    func requestState(connection: DeviceConnection) {
        let packet = NetworkPacket(type: PacketType.lockRequest, body: ["requestLocked": true])
        connection.send(packet: packet)
    }
}
