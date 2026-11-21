//
//  MacVolumePlugin.swift
//  Tether
//
//  KDE Connect's volume panel on the phone, controlling this Mac: the phone
//  asks for the Mac's outputs ("sinks") and sets their volume and mute. Like
//  desktop KDE Connect on macOS, the Mac offers its current output device,
//  and tells the phone whenever the volume changes here, however it changed.
//
//  RemoteVolumePlugin is the other direction: this Mac controlling the phone.
//

import CoreAudio
import Foundation

nonisolated final class MacVolumePlugin: TetherPlugin, @unchecked Sendable {
    static let requestType = PacketType.systemvolumeRequest
    static let reportType = PacketType.systemvolume
    /// The one sink the phone sees: whichever device is the Mac's output.
    private static let sinkName = "default"

    let supportedPacketTypes = [requestType]

    private let queue = DispatchQueue(label: "com.subhashh.tether.macvolume")
    private var connections: [String: DeviceConnection] = [:]
    private var listening = false
    private var watchedDevice: AudioObjectID?
    private var lastSent: (volume: Int, muted: Bool)?

    init() {}

    /// KDE Connect on Android never asks for the list; like desktop KDE
    /// Connect, the Mac sends it as soon as the phone connects.
    func onConnected(connection: DeviceConnection) {
        guard let id = connection.peerDeviceInfo?.deviceId else { return }
        queue.async {
            self.connections[id] = connection
            self.startListening()
            connection.send(packet: self.sinkList())
        }
    }

    func onDisconnected(connection: DeviceConnection) {
        guard let id = connection.peerDeviceInfo?.deviceId else { return }
        queue.async { if self.connections[id] === connection { self.connections[id] = nil } }
    }

    func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == Self.requestType else { return }
        queue.async {
            if packet.has("requestSinks") {
                TetherLog("[MacVolume] \(connection.peerDeviceInfo?.deviceName ?? "Phone") asked for this Mac's volume")
                self.startListening()
                connection.send(packet: self.sinkList())
                return
            }
            guard packet.string(for: "name") == Self.sinkName,
                  let device = SystemAudio.defaultOutputDevice() else { return }
            if packet.has("volume") {
                SystemAudio.setVolume(Float32(packet.int(for: "volume")) / 100, on: device)
            }
            if packet.has("muted") {
                SystemAudio.setMuted(packet.bool(for: "muted"), on: device)
            }
        }
    }

    // MARK: - Reports

    private func sinkList() -> NetworkPacket {
        let device = SystemAudio.defaultOutputDevice()
        let volume = device.flatMap(SystemAudio.volume(of:)).map { Int(($0 * 100).rounded()) } ?? 0
        let muted = device.flatMap(SystemAudio.isMuted) ?? false
        lastSent = (volume, muted)
        let sink: [String: Any] = [
            "name": Self.sinkName,
            "description": device.flatMap(SystemAudio.name(of:)) ?? "Mac",
            "volume": volume,
            "muted": muted,
            "maxVolume": 100,
            "enabled": true,
        ]
        return NetworkPacket(type: Self.reportType, body: ["sinkList": [sink]])
    }

    /// Sends the current volume to every connected phone, if it changed.
    private func reportChange() {
        guard let device = SystemAudio.defaultOutputDevice() else { return }
        let volume = SystemAudio.volume(of: device).map { Int(($0 * 100).rounded()) } ?? 0
        let muted = SystemAudio.isMuted(device) ?? false
        guard lastSent?.volume != volume || lastSent?.muted != muted else { return }
        lastSent = (volume, muted)
        let packet = NetworkPacket(type: Self.reportType, body: ["name": Self.sinkName, "volume": volume, "muted": muted])
        for connection in connections.values { connection.send(packet: packet) }
    }

    // MARK: - Core Audio listeners

    private func startListening() {
        guard !listening else { return }
        listening = true
        var address = SystemAudio.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            // A new output device (headphones plugged in): its own volume.
            guard let self else { return }
            self.watch(SystemAudio.defaultOutputDevice())
            for connection in self.connections.values { connection.send(packet: self.sinkList()) }
        }
        watch(SystemAudio.defaultOutputDevice())
    }

    private func watch(_ device: AudioObjectID?) {
        guard device != watchedDevice, let device else { return }
        watchedDevice = device
        for var address in [SystemAudio.volumeAddress, SystemAudio.muteAddress] {
            AudioObjectAddPropertyListenerBlock(device, &address, queue) { [weak self] _, _ in
                self?.reportChange()
            }
        }
    }
}
