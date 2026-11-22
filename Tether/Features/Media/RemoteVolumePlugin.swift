//
//  RemoteVolumePlugin.swift
//  Tether
//

import Foundation
import Combine

/// An audio output on the peer device.
struct AudioSink: Sendable, Equatable, Identifiable {
    let name: String
    let description: String
    let muted: Bool
    let volume: Int
    let maxVolume: Int
    let enabled: Bool

    var id: String { name }

    /// Volume as a 0...1 fraction, for driving a slider.
    var fraction: Double {
        guard maxVolume > 0 else { return 0 }
        return Double(volume) / Double(maxVolume)
    }
}

/// Controls the phone's volume.
///
/// We ask with `kdeconnect.systemvolume.request` (`requestSinks: true` for the full
/// list). The peer answers with `kdeconnect.systemvolume` carrying `sinkList`, and
/// later sends incremental `{name, volume, muted}` updates as the phone changes.
final class RemoteVolumePlugin: ObservableObject, TetherPlugin, @unchecked Sendable {

    let supportedPacketTypes = [PacketType.systemvolume]

    /// Sinks per device id.
    @Published private(set) var sinks: [String: [AudioSink]] = [:]

    init() {}

    func onConnected(connection: DeviceConnection) {
        requestSinks(connection: connection)
    }

    /// Its state belongs to the device, not the connection, and is kept.
    func onConnectionReplaced(old: DeviceConnection, new: DeviceConnection) {}

    func onDisconnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        sinks.removeValue(forKey: deviceId)
    }

    func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == PacketType.systemvolume,
              let deviceId = connection.peerDeviceInfo?.deviceId else { return }

        // Full list refresh.
        let listed = packet.objectArray(for: "sinkList")
        if !listed.isEmpty {
            let list = listed.map { entry in
                AudioSink(
                    name: entry["name"] as? String ?? "",
                    description: entry["description"] as? String ?? "",
                    muted: entry["muted"] as? Bool ?? false,
                    volume: entry["volume"] as? Int ?? 0,
                    maxVolume: entry["maxVolume"] as? Int ?? 100,
                    enabled: entry["enabled"] as? Bool ?? true
                )
            }
            if sinks[deviceId] != list { sinks[deviceId] = list }
            return
        }

        // Incremental update for a single sink.
        guard let name = packet.string(for: "name"),
              var deviceSinks = sinks[deviceId],
              let index = deviceSinks.firstIndex(where: { $0.name == name }) else { return }

        let existing = deviceSinks[index]
        let hasVolume = packet.body["volume"] != nil
        let hasMuted = packet.body["muted"] != nil

        deviceSinks[index] = AudioSink(
            name: existing.name,
            description: existing.description,
            muted: hasMuted ? packet.bool(for: "muted") : existing.muted,
            volume: hasVolume ? packet.int(for: "volume") : existing.volume,
            maxVolume: existing.maxVolume,
            enabled: existing.enabled
        )
        if sinks[deviceId] != deviceSinks { sinks[deviceId] = deviceSinks }
    }

    func requestSinks(connection: DeviceConnection) {
        let packet = NetworkPacket(type: PacketType.systemvolumeRequest, body: ["requestSinks": true])
        connection.send(packet: packet)
    }

    /// Sets a sink's volume. `volume` is in the sink's own 0...maxVolume scale.
    func setVolume(sinkName: String, volume: Int, connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: PacketType.systemvolumeRequest,
            body: ["name": sinkName, "volume": volume]
        )
        connection.send(packet: packet)
    }

    func setMuted(sinkName: String, muted: Bool, connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: PacketType.systemvolumeRequest,
            body: ["name": sinkName, "muted": muted]
        )
        connection.send(packet: packet)
    }
}
