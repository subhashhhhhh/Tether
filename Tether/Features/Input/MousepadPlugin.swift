//
//  MousepadPlugin.swift
//  Tether
//
//  Remote input plugin for touchpad, clicks, scrolling, and keyboard input.
//

import Foundation

final class MousepadPlugin: TetherPlugin, @unchecked Sendable {
    static let requestType = PacketType.mousepadRequest
    static let keyboardStateType = PacketType.mousepadKeyboardstate
    static let echoType = PacketType.mousepadEcho

    var supportedPacketTypes: [String] {
        [Self.requestType]
    }

    init() {}

    func onConnected(connection: DeviceConnection) {
        // Announce that we support keyboard input
        let packet = NetworkPacket(
            type: Self.keyboardStateType,
            body: ["state": AnyCodable(true)]
        )
        connection.send(packet: packet)
        TetherLog("[MousepadPlugin] Sent keyboardstate {state: true} to \(connection.peerDeviceInfo?.deviceName ?? "device")")
    }

    func onDisconnected(connection: DeviceConnection) {}

    func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
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
