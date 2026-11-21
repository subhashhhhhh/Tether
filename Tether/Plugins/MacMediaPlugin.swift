//
//  MacMediaPlugin.swift
//  Tether
//
//  This Mac as a media player in KDE Connect's Multimedia control on the
//  phone: play, pause, next and previous for whatever is playing on the Mac,
//  and its volume. Like desktop KDE Connect on Windows, it's one player that
//  drives the system's media controls rather than one per app. The phone's
//  volume tab for this Mac lives in that same screen, so it needs this player
//  to exist at all.
//
//  What's playing comes from NowPlayingReader. Where macOS won't tell, the
//  phone still gets the controls and the volume, without a title.
//
//  MediaControlPlugin is the other direction: this Mac controlling the phone.
//

import Foundation

public final class MacMediaPlugin: TetherPlugin, @unchecked Sendable {
    static let requestType = PacketType.mprisRequest
    static let reportType = PacketType.mpris
    static let playerName = "This Mac"

    public let supportedPacketTypes = [requestType]

    private let queue = DispatchQueue(label: "com.subhashh.tether.macmedia")
    private var connections: [String: DeviceConnection] = [:]
    private let reader = NowPlayingReader.shared

    public init() {
        reader.onChange = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                let packet = self.nowPlaying(state)
                for connection in self.connections.values { connection.send(packet: packet) }
            }
        }
    }

    /// The reader runs only while a phone is connected.
    public func onConnected(connection: DeviceConnection) {
        guard let id = connection.peerDeviceInfo?.deviceId else { return }
        queue.async {
            if self.connections.isEmpty { self.reader.start() }
            self.connections[id] = connection
        }
    }

    public func onDisconnected(connection: DeviceConnection) {
        guard let id = connection.peerDeviceInfo?.deviceId else { return }
        queue.async {
            guard self.connections[id] === connection else { return }
            self.connections[id] = nil
            if self.connections.isEmpty { self.reader.stop() }
        }
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == Self.requestType else { return }
        queue.async { self.handle(packet, from: connection) }
    }

    private func handle(_ packet: NetworkPacket, from connection: DeviceConnection) {
        if packet.bool(for: "requestPlayerList") || packet.string(for: "player") != Self.playerName {
            TetherLog("[MacMedia] \(connection.peerDeviceInfo?.deviceName ?? "Phone") asked for this Mac's players")
            connection.send(packet: NetworkPacket(type: Self.reportType, body: [
                "playerList": [Self.playerName],
                "supportAlbumArtPayload": true,
            ]))
            return
        }

        // The phone asks for the artwork named in a now-playing report.
        if let url = packet.string(for: "albumArtUrl") {
            sendArtwork(url, to: connection)
            return
        }

        if let action = packet.string(for: "action") {
            perform(action)
            // Report the new state once the player has reacted.
            queue.asyncAfter(deadline: .now() + 0.8) { connection.send(packet: self.nowPlaying(self.reader.state())) }
        }

        // "SetPosition" is milliseconds into the track; "Seek" moves by microseconds.
        if packet.has("SetPosition") {
            reader.seek(to: Double(packet.int64(for: "SetPosition")) / 1000)
        } else if packet.has("Seek"), let state = reader.state() {
            reader.seek(to: state.position + Double(packet.int64(for: "Seek")) / 1_000_000)
        }

        if packet.has("setVolume"), let device = SystemAudio.defaultOutputDevice() {
            SystemAudio.setVolume(Float32(packet.int(for: "setVolume")) / 100, on: device)
        }

        if packet.bool(for: "requestNowPlaying") || packet.bool(for: "requestVolume") {
            connection.send(packet: nowPlaying(reader.state()))
        }
    }

    /// Media keys, which every player obeys (Safari ignores MediaRemote
    /// commands from other apps). There's only a toggle key, so Play and
    /// Pause press it only when the state is the other one, and nothing is
    /// pressed with nothing playing, since ⏯ would then open Music.
    private func perform(_ action: String) {
        let state = reader.state()
        let isPlaying = state?.isPlaying ?? SystemAudio.isPlaying()
        let hasPlayer = state != nil || isPlaying
        let key: InputSynthesizer.MediaKey?
        let fallback: MediaRemote.Command
        switch action {
        case "PlayPause": (key, fallback) = (hasPlayer ? .playPause : nil, .togglePlayPause)
        case "Play": (key, fallback) = (hasPlayer && !isPlaying ? .playPause : nil, .play)
        case "Pause", "Stop": (key, fallback) = (isPlaying ? .playPause : nil, .pause)
        case "Next": (key, fallback) = (hasPlayer ? .next : nil, .nextTrack)
        case "Previous": (key, fallback) = (hasPlayer ? .previous : nil, .previousTrack)
        default: return
        }
        guard let key else { return }
        if !InputSynthesizer.shared.pressMediaKey(key) {
            TetherLog("[MacMedia] No Accessibility access for media keys; some players will ignore \(action)")
            MediaRemote.send(fallback)
        }
    }

    private func nowPlaying(_ state: MacNowPlaying?) -> NetworkPacket {
        let volume = SystemAudio.defaultOutputDevice().flatMap(SystemAudio.volume(of:)).map { Int(($0 * 100).rounded()) } ?? 0
        return NetworkPacket(type: Self.reportType, body: [
            "player": Self.playerName,
            "title": state?.title ?? "Media on this Mac",
            "artist": state?.artist ?? "",
            "album": state?.album ?? "",
            "isPlaying": state?.isPlaying ?? SystemAudio.isPlaying(),
            "canPause": true,
            "canPlay": true,
            "canGoNext": true,
            "canGoPrevious": true,
            // Safari ignores seeking from other apps.
            "canSeek": (state?.duration ?? 0) > 0 && state?.app != "com.apple.Safari",
            // Milliseconds.
            "pos": Int64((state?.position ?? 0) * 1000),
            "length": Int64((state?.duration ?? 0) * 1000),
            "volume": volume,
            "albumArtUrl": state?.artworkURL ?? "",
        ])
    }

    // MARK: - Artwork

    private var uploaders: [UUID: PayloadUploader] = [:]

    /// Sends the artwork as a payload, the way KDE Connect transfers files.
    private func sendArtwork(_ url: String, to connection: DeviceConnection) {
        guard let artwork = reader.artwork(named: url) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tether-artwork-\(UUID().uuidString)")
        guard (try? artwork.data.write(to: file)) != nil else { return }

        let id = UUID()
        let uploader = PayloadUploader()
        uploaders[id] = uploader
        uploader.start(
            fileURL: file,
            expectedPeerFingerprint: connection.peerCertificateFingerprint,
            onReady: { offer in
                connection.send(packet: NetworkPacket(
                    type: Self.reportType,
                    body: ["player": Self.playerName, "transferringAlbumArt": true, "albumArtUrl": url],
                    payloadSize: offer.size,
                    payloadTransferInfo: ["port": Int(offer.port)]
                ))
            },
            onProgress: { _ in },
            onComplete: { [weak self] _ in
                try? FileManager.default.removeItem(at: file)
                self?.queue.async { self?.uploaders[id] = nil }
            }
        )
    }
}
