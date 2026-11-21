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

}

/// Controls the phone's media player (upstream's `mprisremote`).
///
/// Commands go out as `kdeconnect.mpris.request`; state comes back as
/// `kdeconnect.mpris`. Album art, when offered, arrives as a separate payload
/// flagged by `transferringAlbumArt`.
public final class MediaControlPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {

    public let supportedPacketTypes = [PacketType.mpris]

    /// The shown player's track, per device id.
    @Published public private(set) var nowPlaying: [String: NowPlaying] = [:]

    /// Each player's state, by device then player. The phone reports each
    /// player separately; merging them made the display flip between apps.
    private var playerStates: [String: [String: NowPlaying]] = [:]
    /// Each player's art URL, by device then player.
    private var artURLByPlayer: [String: [String: String]] = [:]
    /// The player chosen in the picker, per device; none means follow
    /// whichever is playing.
    @Published public private(set) var chosenPlayer: [String: String] = [:]

    /// Album art per device id, decoded from the payload when offered.
    @Published public private(set) var albumArt: [String: Data] = [:]

    /// Players advertised by the peer.
    @Published public private(set) var players: [String: [String]] = [:]

    /// The art each device's current track points to, as the phone names it.
    private var albumArtURLs: [String: String] = [:]

    public init() {}

    public func onConnected(connection: DeviceConnection) {
        requestState(connection: connection)
    }

    /// Its state belongs to the device, not the connection, and is kept.
    public func onConnectionReplaced(old: DeviceConnection, new: DeviceConnection) {}

    public func onDisconnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        nowPlaying.removeValue(forKey: deviceId)
        playerStates.removeValue(forKey: deviceId)
        artURLByPlayer.removeValue(forKey: deviceId)
        albumArt.removeValue(forKey: deviceId)
        albumArtURLs.removeValue(forKey: deviceId)
        players.removeValue(forKey: deviceId)
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == PacketType.mpris,
              let deviceId = connection.peerDeviceInfo?.deviceId else { return }

        if packet.body["playerList"] != nil {
            let playerList = packet.stringArray(for: "playerList")
            let known = Set(playerStates[deviceId]?.keys.map { $0 } ?? [])
            if players[deviceId] != playerList { players[deviceId] = playerList }
            playerStates[deviceId] = playerStates[deviceId]?.filter { playerList.contains($0.key) }
            if let chosen = chosenPlayer[deviceId], !playerList.contains(chosen) { chosenPlayer[deviceId] = nil }
            // Each player answers for itself, so a new one is asked directly.
            for player in playerList where !known.contains(player) {
                connection.send(packet: NetworkPacket(
                    type: PacketType.mprisRequest,
                    body: ["player": player, "requestNowPlaying": true, "requestVolume": true]
                ))
            }
            if playerList.isEmpty {
                nowPlaying.removeValue(forKey: deviceId)
                albumArt.removeValue(forKey: deviceId)
                albumArtURLs.removeValue(forKey: deviceId)
            }
        }

        guard let player = packet.string(for: "player"), !player.isEmpty else { return }
        var state = playerStates[deviceId]?[player] ?? NowPlaying()
        state.player = player
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

        playerStates[deviceId, default: [:]][player] = state
        if let url = packet.string(for: "albumArtUrl"), !packet.bool(for: "transferringAlbumArt") {
            artURLByPlayer[deviceId, default: [:]][player] = url
        }
        showCurrentPlayer(deviceId: deviceId, connection: connection)
    }

    /// The player to show: the one chosen, else the one shown while it plays,
    /// else any that's playing, else the one shown, else the first.
    private func currentPlayerName(deviceId: String) -> String? {
        Self.playerToShow(chosen: chosenPlayer[deviceId], shown: nowPlaying[deviceId]?.player,
                          states: playerStates[deviceId] ?? [:], order: players[deviceId] ?? [])
    }

    static func playerToShow(chosen: String?, shown: String?, states: [String: NowPlaying], order: [String]) -> String? {
        if let chosen, states[chosen] != nil { return chosen }
        if let shown, states[shown]?.isPlaying == true { return shown }
        if let playing = order.first(where: { states[$0]?.isPlaying == true }) { return playing }
        if let shown, states[shown] != nil { return shown }
        return order.first { states[$0] != nil } ?? states.keys.sorted().first
    }

    private func showCurrentPlayer(deviceId: String, connection: DeviceConnection) {
        guard let name = currentPlayerName(deviceId: deviceId), let state = playerStates[deviceId]?[name] else { return }
        if nowPlaying[deviceId] != state { nowPlaying[deviceId] = state }

        // The phone names the track's art by URL and sends the image only when
        // asked for that URL, as a payload on a later packet.
        if let url = artURLByPlayer[deviceId]?[name], url != albumArtURLs[deviceId] {
            albumArtURLs[deviceId] = url
            if url.isEmpty {
                albumArt.removeValue(forKey: deviceId)
            } else {
                connection.send(packet: NetworkPacket(
                    type: PacketType.mprisRequest,
                    body: ["player": name, "albumArtUrl": url]
                ))
            }
        }
    }

    /// Shows and controls this player; nil goes back to following whichever
    /// is playing.
    public func choosePlayer(_ player: String?, connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        chosenPlayer[deviceId] = player
        showCurrentPlayer(deviceId: deviceId, connection: connection)
        if let player {
            connection.send(packet: NetworkPacket(
                type: PacketType.mprisRequest,
                body: ["player": player, "requestNowPlaying": true, "requestVolume": true]
            ))
        }
    }

    public func handlePayload(connection: DeviceConnection, packet: NetworkPacket, fileURL: URL) {
        guard packet.type == PacketType.mpris,
              let deviceId = connection.peerDeviceInfo?.deviceId,
              packet.bool(for: "transferringAlbumArt"),
              // Art for a track that's already been replaced is stale.
              packet.string(for: "albumArtUrl") == albumArtURLs[deviceId],
              let data = try? Data(contentsOf: fileURL) else { return }

        albumArt[deviceId] = data
    }

    // MARK: - Commands

    public func requestState(connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: PacketType.mprisRequest,
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
        connection.send(packet: NetworkPacket(type: PacketType.mprisRequest, body: body))
    }

    public func setVolume(_ volume: Int, connection: DeviceConnection) {
        var body: [String: Any] = ["setVolume": max(0, min(100, volume))]
        if let player = currentPlayer(connection: connection) {
            body["player"] = player
        }
        connection.send(packet: NetworkPacket(type: PacketType.mprisRequest, body: body))
    }

    /// Moves to a position in the track, in milliseconds. The phone takes
    /// only an absolute position; it ignores a relative `Seek`.
    public func setPosition(milliseconds: Int, connection: DeviceConnection) {
        var body: [String: Any] = ["SetPosition": max(0, milliseconds)]
        if let player = currentPlayer(connection: connection) {
            body["player"] = player
        }
        connection.send(packet: NetworkPacket(type: PacketType.mprisRequest, body: body))
    }

    private func currentPlayer(connection: DeviceConnection) -> String? {
        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let player = nowPlaying[deviceId]?.player,
              !player.isEmpty else { return nil }
        return player
    }
}
