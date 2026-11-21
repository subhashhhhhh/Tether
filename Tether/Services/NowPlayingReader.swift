//
//  NowPlayingReader.swift
//  Tether
//
//  What's playing on the Mac (a song in Music, a video in Safari), for the
//  phone's Multimedia control. Since macOS 15.4 only Apple-signed programs may
//  read Now Playing, so this runs MediaRemoteAdapter (Vendor/, BSD licence)
//  through /usr/bin/perl, which streams changes as JSON lines. If a future
//  macOS closes that door, the stream ends, the reader gives up after a few
//  tries, and the phone keeps the controls without a title.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct MacNowPlaying: Sendable, Equatable {
    var title = ""
    var artist = ""
    var album = ""
    /// The app playing it, e.g. com.apple.Safari for a video in Safari.
    var app = ""
    var isPlaying = false
    /// Seconds.
    var duration: Double = 0
    /// Seconds into the track at `timestamp`.
    var elapsed: Double = 0
    var timestamp = Date()
    /// Names the track's artwork once it's been read, for the phone to ask for.
    var artworkURL: String?

    /// Changes when the track does.
    var trackKey: String { "\(app)|\(title)|\(artist)|\(album)" }

    /// Where playback is now, estimated from the last report.
    var position: Double {
        let now = elapsed + (isPlaying ? Date().timeIntervalSince(timestamp) : 0)
        return duration > 0 ? min(now, duration) : now
    }
}

nonisolated final class NowPlayingReader: @unchecked Sendable {
    static let shared = NowPlayingReader()

    /// Called on the reader's queue whenever what's playing changes.
    var onChange: ((MacNowPlaying?) -> Void)?

    private let queue = DispatchQueue(label: "com.subhashh.tether.nowplaying")
    private var process: Process?
    private var buffer = Data()
    private var wanted = false
    private var failures = 0
    private(set) var current: MacNowPlaying?
    /// The current track's artwork, read once per track.
    private var artwork: (url: String, data: Data, mimeType: String)?

    private init() {
        // The reader is a separate process; it would outlive Tether otherwise.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.sync {
                self?.wanted = false
                self?.process?.terminate()
            }
        }
    }

    private var script: URL? { Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl") }
    private var framework: URL? { Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework") }

    func start() {
        queue.async {
            self.wanted = true
            self.failures = 0
            self.launch()
        }
    }

    func stop() {
        queue.async {
            self.wanted = false
            self.process?.terminate()
            self.process = nil
        }
    }

    func state() -> MacNowPlaying? {
        queue.sync { current }
    }

    /// The artwork named `url`, if it's still the current track's.
    func artwork(named url: String) -> (data: Data, mimeType: String)? {
        queue.sync {
            guard let artwork, artwork.url == url else { return nil }
            return (artwork.data, artwork.mimeType)
        }
    }

    /// Moves playback to `seconds` into the track.
    func seek(to seconds: Double) {
        guard let script, let framework else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "seek", String(Int64(max(seconds, 0) * 1_000_000))]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Stream

    private func launch() {
        guard wanted, process == nil, let script, let framework else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "stream", "--no-diff", "--no-artwork", "--debounce=200"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let started = Date()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.queue.async {
                guard let self else { return }
                self.process = nil
                guard self.wanted else { return }
                // A stream that dies right away won't work on this macOS.
                self.failures = Date().timeIntervalSince(started) < 10 ? self.failures + 1 : 0
                guard self.failures < 3 else {
                    TetherLog("[NowPlaying] The Now Playing reader keeps stopping; the phone will show controls only")
                    self.publish(nil)
                    return
                }
                self.queue.asyncAfter(deadline: .now() + 5) { self.launch() }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            TetherLog("[NowPlaying] Couldn't start the Now Playing reader: \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            publish(Self.parse(payload))
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    static func parse(_ payload: [String: Any]) -> MacNowPlaying? {
        guard let title = payload["title"] as? String, !title.isEmpty else { return nil }
        var state = MacNowPlaying()
        state.title = title
        state.artist = payload["artist"] as? String ?? ""
        state.album = payload["album"] as? String ?? ""
        state.app = payload["parentApplicationBundleIdentifier"] as? String ?? payload["bundleIdentifier"] as? String ?? ""
        state.isPlaying = payload["playing"] as? Bool ?? false
        state.duration = payload["duration"] as? Double ?? 0
        state.elapsed = payload["elapsedTime"] as? Double ?? 0
        if let stamp = payload["timestamp"] as? String, let date = Self.isoFormatter.date(from: stamp) {
            state.timestamp = date
        }
        return state
    }

    private func publish(_ state: MacNowPlaying?) {
        var state = state
        let newTrack = state?.trackKey != current?.trackKey
        if !newTrack { state?.artworkURL = current?.artworkURL }
        guard state != current else { return }
        current = state
        onChange?(state)
        if newTrack {
            artwork = nil
            if let state { fetchArtwork(for: state.trackKey) }
        }
    }

    /// Artwork as a JPEG or PNG no bigger than 1024 px. Safari hands over TIFF
    /// (while calling it JPEG), which Android can't decode, so the phone
    /// showed no art for videos.
    nonisolated static func phoneReadable(_ data: Data) -> (Data, String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return nil }
        let size = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]).map {
            max($0[kCGImagePropertyPixelWidth] as? Int ?? 0, $0[kCGImagePropertyPixelHeight] as? Int ?? 0)
        } ?? 0
        if size <= 1024 {
            if type == UTType.jpeg.identifier { return (data, "image/jpeg") }
            if type == UTType.png.identifier { return (data, "image/png") }
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, "image/jpeg")
    }

    /// Reads the artwork with a one-off `get`: the stream leaves it out, since
    /// it would repeat hundreds of kilobytes in every update.
    private func fetchArtwork(for trackKey: String) {
        guard let script, let framework else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [script.path, framework.path, "get"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let payload = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
                  let base64 = payload["artworkData"] as? String,
                  let raw = Data(base64Encoded: base64), !raw.isEmpty,
                  let (data, mimeType) = Self.phoneReadable(raw) else { return }
            self.queue.async {
                guard var state = self.current, state.trackKey == trackKey else { return }
                // A name that changes with the image, so the phone never shows
                // the previous track's art from its cache. KDE Connect on
                // Android only asks the computer for file: and kdeconnect: URLs.
                let url = "kdeconnect://artwork/\(data.hashValue.magnitude)"
                self.artwork = (url, data, mimeType)
                state.artworkURL = url
                self.current = state
                self.onChange?(state)
            }
        }
    }
}
