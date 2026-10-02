//
//  MousepadPlugin.swift
//  Tether
//
//  Remote input plugin for touchpad, clicks, scrolling, and keyboard input.
//

import Foundation

public final class MousepadPlugin: TetherPlugin, @unchecked Sendable {
    public static let requestType = "kdeconnect.mousepad.request"
    public static let keyboardStateType = "kdeconnect.mousepad.keyboardstate"
    public static let echoType = "kdeconnect.mousepad.echo"

    public var supportedPacketTypes: [String] {
        [Self.requestType]
    }

    public init() {}

    public func onConnected(connection: DeviceConnection) {
        // Announce that we support keyboard input
        let packet = NetworkPacket(
            type: Self.keyboardStateType,
            body: ["state": AnyCodable(true)]
        )
        connection.send(packet: packet)
        TetherLog("[MousepadPlugin] Sent keyboardstate {state: true} to \(connection.peerDeviceInfo?.deviceName ?? "device")")
    }

    public func onDisconnected(connection: DeviceConnection) {}

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == Self.requestType else { return }

        // Synthesize input event
        InputSynthesizer.shared.handlePacket(packet)

        // Send ack if requested
        if packet.bool(for: "sendAck") == true {
            let echo = NetworkPacket(
                type: Self.echoType,
                body: ["isAck": AnyCodable(true)]
            )
            connection.send(packet: echo)
        }
    }
}
