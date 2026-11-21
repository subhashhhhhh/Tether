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

    /// The same verified device opened a new connection and the old one is
    /// being closed, as when the phone rejoins Wi-Fi. The phone keeps its
    /// own state across this, so a plugin should too, and only move to the
    /// new connection. By default it's treated as a fresh connect.
    func onConnectionReplaced(old: DeviceConnection, new: DeviceConnection)

    // The payload hooks must be requirements here, not only extension methods:
    // the service calls them through `any TetherPlugin`, and an extension-only
    // method is dispatched statically to the empty default, so a plugin's own
    // implementation would never run. (That is how received files were lost.)

    /// Called after a packet that announced a binary payload has finished downloading.
    ///
    /// Payloads travel over a separate TLS connection, so `handlePacket` fires first
    /// (with the announcement) and this fires later. The bytes are streamed to a
    /// temporary file rather than held in memory; a plugin that wants to keep it
    /// must move or copy it before returning; it is deleted afterwards.
    func handlePayload(connection: DeviceConnection, packet: NetworkPacket, fileURL: URL)

    /// Download progress for a payload announced by `packet`, from 0 to 1.
    func handlePayloadProgress(connection: DeviceConnection, packet: NetworkPacket, fraction: Double)

    /// The payload announced by `packet` could not be received.
    func handlePayloadFailure(connection: DeviceConnection, packet: NetworkPacket, error: Error)
}

public extension TetherPlugin {
    func onConnectionReplaced(old: DeviceConnection, new: DeviceConnection) {
        onConnected(connection: new)
        onDisconnected(connection: old)
    }
    func handlePayload(connection: DeviceConnection, packet: NetworkPacket, fileURL: URL) {}
    func handlePayloadProgress(connection: DeviceConnection, packet: NetworkPacket, fraction: Double) {}
    func handlePayloadFailure(connection: DeviceConnection, packet: NetworkPacket, error: Error) {}
}
