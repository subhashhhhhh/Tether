//
//  FindMyPhonePlugin.swift
//  Tether
//

import Foundation

/// Rings the phone, and rings this Mac when the phone asks ("Ring" in KDE
/// Connect's device menu on the phone). The request has no body either way.
public final class FindMyPhonePlugin: TetherPlugin, @unchecked Sendable {

    public let supportedPacketTypes: [String] = [PacketType.findmyphoneRequest]

    public init() {}

    public func onConnected(connection: DeviceConnection) {}
    public func onDisconnected(connection: DeviceConnection) {}
    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == PacketType.findmyphoneRequest else { return }
        let name = connection.peerDeviceInfo?.deviceName ?? "Your phone"
        Task { @MainActor in MacRinger.shared.toggle(from: name) }
    }

    /// Asks the peer to ring at full volume until dismissed.
    public func ring(deviceId: String, connection: DeviceConnection) {
        let packet = NetworkPacket(type: PacketType.findmyphoneRequest, body: [:])
        connection.send(packet: packet)
        TetherLog("[FindMyPhonePlugin] Sent ring request to \(deviceId)")
    }
}
