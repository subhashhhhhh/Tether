//
//  PhoneNowPlaying.swift
//  Tether
//
//  What's playing on the phone, shown in macOS Now Playing (Control Center,
//  the menu bar's Now Playing, and apps that read it), with its play,
//  pause, skip and scrub controls sent back to the phone. As KDE Connect
//  desktop does on macOS.
//

import AppKit
import Combine
import MediaPlayer

@MainActor
final class PhoneNowPlaying {
    static let shared = PhoneNowPlaying()

    /// Settings › General. On unless turned off.
    static let settingKey = "tether_phone_now_playing"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    private var subscription: AnyCancellable?
    private var settingObserver: NSObjectProtocol?
    private var deviceId: String?
    private var shown: NowPlaying?
    private var shownArt: Data?
    private var commandsAdded = false

    func start() {
        guard subscription == nil else { return }
        let service = TetherService.shared
        subscription = service.mediaControlPlugin.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.update() }
        settingObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        let plugin = TetherService.shared.mediaControlPlugin
        // The phone that's playing, else one with a track.
        let candidates = plugin.nowPlaying.filter { !$0.value.title.isEmpty }
        let pick = candidates.first { $0.value.isPlaying } ?? candidates.first
        guard Self.isEnabled, let (id, track) = pick else {
            clear()
            return
        }
        addCommandsOnce()
        let art = plugin.albumArt[id]
        guard id != deviceId || track != shown || art != shownArt else { return }
        deviceId = id
        shown = track
        shownArt = art

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyPlaybackRate: track.isPlaying ? 1.0 : 0.0,
        ]
        if track.length > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(track.length) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(track.position) / 1000
        }
        if let art, let image = ImageCache.image(art, key: "now-playing-\(id)", maxPixels: 600) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = track.isPlaying ? .playing : .paused

        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = track.canGoNext
        commands.previousTrackCommand.isEnabled = track.canGoPrevious
        commands.changePlaybackPositionCommand.isEnabled = track.canSeek && track.length > 0
    }

    private func clear() {
        guard deviceId != nil else { return }
        deviceId = nil
        shown = nil
        shownArt = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func addCommandsOnce() {
        guard !commandsAdded else { return }
        commandsAdded = true
        let commands = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, String)] = [
            (commands.playCommand, "Play"),
            (commands.pauseCommand, "Pause"),
            (commands.togglePlayPauseCommand, "PlayPause"),
            (commands.nextTrackCommand, "Next"),
            (commands.previousTrackCommand, "Previous"),
        ]
        for (command, action) in actions {
            command.addTarget { [weak self] _ in
                guard let deviceId = self?.deviceId else { return .noActionableNowPlayingItem }
                TetherService.shared.mediaAction(action, deviceId: deviceId)
                return .success
            }
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let deviceId = self?.deviceId,
                  let event = event as? MPChangePlaybackPositionCommandEvent,
                  let connection = TetherService.shared.connection(for: deviceId) else { return .commandFailed }
            TetherService.shared.mediaControlPlugin.setPosition(milliseconds: Int(event.positionTime * 1000), connection: connection)
            return .success
        }
    }
}
