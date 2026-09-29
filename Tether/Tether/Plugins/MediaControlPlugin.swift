//
//  MediaControlPlugin.swift
//  Tether
//

import Foundation
import Combine

/// What the phone's media player is currently doing.
public struct NowPlaying: Sendable, Equatable {
    public var player: String = ""
    public var title: String = ""
    public var artist: String = ""
    public var album: String = ""

    /// Track length in milliseconds, 0 when unknown (live streams).
    public var length: Int = 0
    /// Playback position in milliseconds.
    public var position: Int = 0

    public var isPlaying: Bool = false
    public var volume: Int = 0

    public var canPlay: Bool = false
    public var canPause: Bool = false
    public var canGoNext: Bool = false
    public var canGoPrevious: Bool = false
    public var canSeek: Bool = false

    public var hasTrack: Bool { !title.isEmpty }

    /// Elapsed time as mm:ss, empty when the length is unknown.
    public var elapsedLabel: String {
        guard length > 0 else { return "" }
        let seconds = max(0, position / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Controls the phone's media player (upstream's `mprisremote`).
///
/// Commands go out as `kdeconnect.mpris.request`; state comes back as
/// `kdeconnect.mpris`. Album art, when offered, arrives as a separate payload
/// flagged by `transferringAlbumArt`.
public final class MediaControlPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {

    public let supportedPacketTypes = ["kdeconnect.mpris"]

    /// Current track per device id.
    @Published public private(set) var nowPlaying: [String: NowPlaying] = [:]

    /// Album art per device id, decoded from the payload when offered.
    @Published public private(set) var albumArt: [String: Data] = [:]

    /// Players advertised by the peer.
    @Published public private(set) var players: [String: [String]] = [:]

    public init() {}

    public func onConnected(connection: DeviceConnection) {
        requestState(connection: connection)
    }

    public func onDisconnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        nowPlaying.removeValue(forKey: deviceId)
        albumArt.removeValue(forKey: deviceId)
        players.removeValue(forKey: deviceId)
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.mpris",
              let deviceId = connection.peerDeviceInfo?.deviceId else { return }

        let playerList = packet.stringArray(for: "playerList")
        if !playerList.isEmpty {
            players[deviceId] = playerList
        }

        var state = nowPlaying[deviceId] ?? NowPlaying()

        if let player = packet.string(for: "player") { state.player = player }
        if let title = packet.string(for: "title") { state.title = title }
        if let artist = packet.string(for: "artist") { state.artist = artist }
        if let album = packet.string(for: "album") { state.album = album }

        if packet.body["length"] != nil { state.length = packet.int(for: "length") }
        if packet.body["pos"] != nil { state.position = packet.int(for: "pos") }
        if packet.body["volume"] != nil { state.volume = packet.int(for: "volume") }
        if packet.body["isPlaying"] != nil { state.isPlaying = packet.bool(for: "isPlaying") }

        if packet.body["canPlay"] != nil { state.canPlay = packet.bool(for: "canPlay") }
        if packet.body["canPause"] != nil { state.canPause = packet.bool(for: "canPause") }
        if packet.body["canGoNext"] != nil { state.canGoNext = packet.bool(for: "canGoNext") }
        if packet.body["canGoPrevious"] != nil { state.canGoPrevious = packet.bool(for: "canGoPrevious") }
        if packet.body["canSeek"] != nil { state.canSeek = packet.bool(for: "canSeek") }

        nowPlaying[deviceId] = state

        // Metadata-only packets announce art separately; the bytes arrive later.
        if packet.bool(for: "transferringAlbumArt") {
            TetherLog("[MediaControlPlugin] Album art payload announced by \(deviceId)")
        }
    }

    public func handlePayload(connection: DeviceConnection, packet: NetworkPacket, data: Data) {
        guard packet.type == "kdeconnect.mpris",
              let deviceId = connection.peerDeviceInfo?.deviceId,
              packet.bool(for: "transferringAlbumArt") else { return }

        albumArt[deviceId] = data
    }

    // MARK: - Commands

    public func requestState(connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: "kdeconnect.mpris.request",
            body: [
                "requestPlayerList": true,
                "requestNowPlaying": true,
                "requestVolume": true
            ]
        )
        connection.send(packet: packet)
    }

    /// Sends a transport action: Play, Pause, PlayPause, Next or Previous.
    public func sendAction(_ action: String, connection: DeviceConnection) {
        var body: [String: Any] = ["action": action]
        if let player = currentPlayer(connection: connection) {
            body["player"] = player
        }
        connection.send(packet: NetworkPacket(type: "kdeconnect.mpris.request", body: body))
    }

    public func setVolume(_ volume: Int, connection: DeviceConnection) {
        var body: [String: Any] = ["setVolume": max(0, min(100, volume))]
        if let player = currentPlayer(connection: connection) {
            body["player"] = player
        }
        connection.send(packet: NetworkPacket(type: "kdeconnect.mpris.request", body: body))
    }

    /// Seeks by a relative offset in milliseconds.
    public func seek(offsetMilliseconds: Int, connection: DeviceConnection) {
        var body: [String: Any] = ["Seek": offsetMilliseconds]
        if let player = currentPlayer(connection: connection) {
            body["player"] = player
        }
        connection.send(packet: NetworkPacket(type: "kdeconnect.mpris.request", body: body))
    }

    private func currentPlayer(connection: DeviceConnection) -> String? {
        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let player = nowPlaying[deviceId]?.player,
              !player.isEmpty else { return nil }
        return player
    }
}
