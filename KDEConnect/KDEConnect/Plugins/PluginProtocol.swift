//
//  PluginProtocol.swift
//  KDEConnect
//

import Foundation

public protocol KDEConnectPlugin: AnyObject, Sendable {
    var supportedPacketTypes: [String] { get }
    func onConnected(connection: DeviceConnection)
    func onDisconnected(connection: DeviceConnection)
    func handlePacket(connection: DeviceConnection, packet: NetworkPacket)
}
