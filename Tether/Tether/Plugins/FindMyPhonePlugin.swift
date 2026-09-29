//
//  FindMyPhonePlugin.swift
//  Tether
//

import Foundation

/// Rings the phone. Outgoing only — there is nothing to handle in the other
/// direction, since a ring request carries no body and expects no reply.
public final class FindMyPhonePlugin: TetherPlugin, @unchecked Sendable {

    public let supportedPacketTypes: [String] = []

    public init() {}

    public func onConnected(connection: DeviceConnection) {}
    public func onDisconnected(connection: DeviceConnection) {}
    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {}

    /// Asks the peer to ring at full volume until dismissed.
    public func ring(deviceId: String, connection: DeviceConnection) {
        let packet = NetworkPacket(type: "kdeconnect.findmyphone.request", body: [:])
        connection.send(packet: packet)
        TetherLog("[FindMyPhonePlugin] Sent ring request to \(deviceId)")
    }
}
