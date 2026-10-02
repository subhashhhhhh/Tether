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
public final class LockDevicePlugin: ObservableObject, TetherPlugin, @unchecked Sendable {

    public let supportedPacketTypes = ["kdeconnect.lock"]

    /// Last reported lock state per device id.
    @Published public private(set) var isLocked: [String: Bool] = [:]

    public init() {}

    public func onConnected(connection: DeviceConnection) {}

    public func onDisconnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        isLocked.removeValue(forKey: deviceId)
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.lock",
              let deviceId = connection.peerDeviceInfo?.deviceId else { return }

        isLocked[deviceId] = packet.bool(for: "isLocked", default: false)
    }

    /// Asks the peer to lock itself.
    public func lock(connection: DeviceConnection) {
        let packet = NetworkPacket(type: "kdeconnect.lock.request", body: ["setLocked": true])
        connection.send(packet: packet)
        TetherLog("[LockDevicePlugin] Sent lock request")
    }

    /// Asks the peer to report its current lock state.
    public func requestState(connection: DeviceConnection) {
        let packet = NetworkPacket(type: "kdeconnect.lock.request", body: ["requestLocked": true])
        connection.send(packet: packet)
    }
}
