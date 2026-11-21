//
//  CallMediaPauser.swift
//  Tether
//
//  Pauses whatever is playing on the Mac while the phone rings or a call is
//  under way, and resumes it afterwards, like desktop KDE Connect's "Pause
//  media during calls". It only resumes what it paused itself.
//

import Foundation

@MainActor
final class CallMediaPauser {
    static let shared = CallMediaPauser()

    /// Settings › General › "Pause media during calls". On by default.
    static let settingKey = "tether_pause_media_during_calls"

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true
    }

    /// Phones with a call ringing or under way. Keyed by phone, not by event:
    /// an answered call goes from ringing to talking, and the phone only ends
    /// the last one.
    private var activeCalls = Set<String>()
    private var pausedForCall = false
    private var resumeTask: Task<Void, Never>?

    func callStarted(_ key: String) {
        activeCalls.insert(key)
        resumeTask?.cancel()
        // The Now Playing reader knows whether something is playing; without
        // it, any sound counts.
        let isPlaying = NowPlayingReader.shared.state()?.isPlaying ?? SystemAudio.isPlaying()
        guard isEnabled, !pausedForCall, isPlaying else { return }
        Self.press(.pause)
        pausedForCall = true
        TetherLog("[Calls] Paused media for a call")
    }

    func callEnded(_ key: String) {
        activeCalls.remove(key)
        guard activeCalls.isEmpty, pausedForCall else { return }
        // Ringing ends just before "talking" starts when a call is answered;
        // waiting a moment keeps the music from blipping back on in between.
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, activeCalls.isEmpty, pausedForCall else { return }
            pausedForCall = false
            Self.press(.play)
            TetherLog("[Calls] Resumed media after the call")
        }
    }

    /// The ⏯ key, which every player obeys, or a MediaRemote command without
    /// Accessibility access. Only called when the state is known to flip.
    private static func press(_ command: MediaRemote.Command) {
        if !InputSynthesizer.shared.pressMediaKey(.playPause) {
            MediaRemote.send(command)
        }
    }
}
