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
