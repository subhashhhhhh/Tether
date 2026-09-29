//
//  PluginProtocol.swift
//  Tether
//

import Foundation

public protocol TetherPlugin: AnyObject, Sendable {
    var supportedPacketTypes: [String] { get }
    func onConnected(connection: DeviceConnection)
    func onDisconnected(connection: DeviceConnection)
    func handlePacket(connection: DeviceConnection, packet: NetworkPacket)
}

public extension TetherPlugin {
    /// Called after a packet that announced a binary payload has finished downloading.
    ///
    /// Payloads travel over a separate TLS connection, so `handlePacket` fires first
    /// (with the announcement) and this fires later (with the bytes). Plugins that
    /// never receive payloads can ignore it.
    func handlePayload(connection: DeviceConnection, packet: NetworkPacket, data: Data) {}
}
