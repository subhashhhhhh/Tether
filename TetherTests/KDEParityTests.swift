//
//  KDEParityTests.swift
//  TetherTests
//
//  Cases KDE Connect's own tests cover (sendfiletest.cpp, SMS and mpris
//  helpers) that Tether had no tests for.
//

import Foundation
import Testing
@testable import Tether

// MARK: - File transfer

/// One at a time: they share the folder downloads land in.
@Suite(.serialized)
struct PayloadEdgeCaseTests {
    private func temporaryFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-edge-\(UUID().uuidString).bin")
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 13) }).write(to: url)
        return url
    }

    /// Serves `file` and downloads it, announcing `announcedSize`.
    private func transfer(_ file: URL, announcedSize: @escaping @Sendable (Int64) -> Int64,
                          cancelAfterFirstChunk: Bool = false) async -> Result<Data, Error> {
        let uploader = PayloadUploader()
        let once = Once()
        let handleBox = HandleBox()
        let result: Result<Data, Error> = await withCheckedContinuation { continuation in
            uploader.start(
                fileURL: file,
                onReady: { offer in
                    handleBox.handle = PayloadDownloader.download(
                        host: "127.0.0.1",
                        port: offer.port,
                        size: announcedSize(offer.size),
                        expectedPeerFingerprint: DeviceIdentity.shared.certificateFingerprint,
                        onProgress: { _ in if cancelAfterFirstChunk { handleBox.handle?.cancel() } }
                    ) { result in
                        guard once.claim() else { return }
                        continuation.resume(returning: result.flatMap { url in
                            defer { try? FileManager.default.removeItem(at: url) }
                            return Result { try Data(contentsOf: url) }
                        })
                    }
                },
                onProgress: { _ in },
                onComplete: { _ in }
            )
        }
        uploader.cancel()
        return result
    }

    @Test func readsAFileOfUnknownSizeToTheEnd() async throws {
        let file = try temporaryFile(bytes: 200 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        let received = try await transfer(file, announcedSize: { _ in -1 }).get()
        #expect(received == (try Data(contentsOf: file)))
    }

    @Test func makesAnEmptyFileWithoutATransfer() async throws {
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            // Nothing listens on this port: a zero-byte file mustn't need one.
            PayloadDownloader.download(host: "127.0.0.1", port: 9, size: 0, expectedPeerFingerprint: nil) {
                continuation.resume(returning: $0)
            }
        }
        let url = try result.get()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect((try Data(contentsOf: url)).isEmpty)
    }

    @Test func failsWhenThePhoneSendsLessThanAnnounced() async throws {
        let file = try temporaryFile(bytes: 64 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await transfer(file, announcedSize: { $0 + 4096 })
        guard case .failure(PayloadError.peerClosedEarly) = result else {
            Issue.record("expected peerClosedEarly, got \(result)")
            return
        }
    }

    @Test func stopsWhenCancelled() async throws {
        let file = try temporaryFile(bytes: 8 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await transfer(file, announcedSize: { $0 }, cancelAfterFirstChunk: true)
        guard case .failure(PayloadError.cancelled) = result else {
            Issue.record("expected cancelled, got \(result)")
            return
        }
    }

    @Test func leavesNothingBehindWhenATransferFails() async throws {
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: PayloadDownloader.incomingDirectory.path)) ?? [])
        let file = try temporaryFile(bytes: 16 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = await transfer(file, announcedSize: { $0 + 1 })
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: PayloadDownloader.incomingDirectory.path)) ?? [])
        #expect(after.subtracting(before).isEmpty)
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

private final class HandleBox: @unchecked Sendable {
    var handle: PayloadDownloader.Handle?
}

// MARK: - Clipboard

struct ClipboardRuleTests {
    @Test func keepsTheLastThreeNewestFirst() {
        var history: [String] = []
        for text in ["a", "b", "c", "d"] { history = ClipboardPlugin.adding(text, to: history) }
        #expect(history == ["d", "c", "b"])
    }

    @Test func movesARepeatToTheFront() {
        #expect(ClipboardPlugin.adding("b", to: ["c", "b", "a"]) == ["b", "c", "a"])
    }

    @Test func doesNotSendBackWhatCameFromThePhone() {
        #expect(ClipboardPlugin.isEcho("from phone", lastReceived: "from phone", lastSent: "x"))
        #expect(ClipboardPlugin.isEcho("just sent", lastReceived: "x", lastSent: "just sent"))
        #expect(!ClipboardPlugin.isEcho("new copy", lastReceived: "x", lastSent: "y"))
    }

    @Test func ignoresAPhoneClipOlderThanTheMacs() {
        #expect(ClipboardPlugin.isStale(connectTimestamp: 1_000, localChange: 2_000))
        #expect(!ClipboardPlugin.isStale(connectTimestamp: 3_000, localChange: 2_000))
        // A phone that doesn't send a time isn't judged by it.
        #expect(!ClipboardPlugin.isStale(connectTimestamp: 0, localChange: 2_000))
    }
}

// MARK: - Messages

struct SMSParityTests {
    private func message(at seconds: TimeInterval, attachment: String? = nil) -> SMSMessage {
        SMSMessage(body: "hi", addresses: ["+1"], date: Date(timeIntervalSince1970: seconds), type: 1, threadId: 1, read: true,
                   attachments: attachment.map { [SMSAttachment(partId: 1, mimeType: "image/jpeg", uniqueIdentifier: $0)] } ?? [])
    }

    @Test func asksForThePageBeforeTheOldestMessage() throws {
        let loaded = (0..<80).map { message(at: 1_000 + Double($0)) }
        let page = try #require(SMSPlugin.earlierPage(before: loaded.shuffled()))
        #expect(page.start == 1_000_000)
        #expect(page.count == 80)
        #expect(SMSPlugin.earlierPage(before: [message(at: 5)])?.count == 50)
        #expect(SMSPlugin.earlierPage(before: []) == nil)
    }

    @Test func readsGroupMessagesWithEveryAddress() throws {
        let raw: [String: Any] = [
            "_id": "42", "thread_id": 7, "date": 1_700_000_000_000, "type": 1, "read": 1, "event": 3,
            "body": "group hello",
            "addresses": [["address": "+911111111111"], ["address": "+912222222222"], ["address": "+913333333333"]],
        ]
        let message = try #require(SMSMessage.from(dictionary: raw))
        #expect(message.addresses == ["+911111111111", "+912222222222", "+913333333333"])
        #expect(message.phoneId == 42)
        #expect(message.threadId == 7)
    }

    @Test func readsAttachments() throws {
        let raw: [String: Any] = [
            "_id": 9, "thread_id": 3, "date": 1_700_000_000_000, "type": 1, "body": "",
            "addresses": [["address": "+1"]],
            "attachments": [["part_id": 12, "mime_type": "image/jpeg", "encoded_thumbnail": "aGk=", "unique_identifier": "PART_1.jpg"]],
        ]
        let attachment = try #require(SMSMessage.from(dictionary: raw)?.attachments.first)
        #expect(attachment.partId == 12)
        #expect(attachment.mimeType == "image/jpeg")
        #expect(attachment.uniqueIdentifier == "PART_1.jpg")
        #expect(attachment.encodedThumbnail == "aGk=")
    }

    @Test func attachesAFetchedFileInEveryConversation() {
        let url = URL(fileURLWithPath: "/tmp/PART_1.jpg")
        var first = SMSConversation(threadId: 1, addresses: ["+1"])
        first.messages = [message(at: 1, attachment: "PART_1.jpg")]
        var second = SMSConversation(threadId: 2, addresses: ["+2"])
        second.messages = [message(at: 2, attachment: "PART_2.jpg")]
        let threads = SMSPlugin.attaching(url, to: "PART_1.jpg", in: [1: first, 2: second])
        #expect(threads[1]?.messages.first?.attachments.first?.localURL == url)
        #expect(threads[2]?.messages.first?.attachments.first?.localURL == nil)
    }
}

// MARK: - Media

struct MediaPlayerChoiceTests {
    private func state(_ player: String, playing: Bool) -> NowPlaying {
        var state = NowPlaying()
        state.player = player
        state.title = player
        state.isPlaying = playing
        return state
    }

    @Test func followsThePlayerThatIsPlaying() {
        let states = ["Spotify": state("Spotify", playing: false), "YouTube": state("YouTube", playing: true)]
        #expect(MediaControlPlugin.playerToShow(chosen: nil, shown: "Spotify", states: states, order: ["Spotify", "YouTube"]) == "YouTube")
    }

    @Test func keepsShowingAPlayerWhileItPlays() {
        let states = ["Spotify": state("Spotify", playing: true), "YouTube": state("YouTube", playing: true)]
        #expect(MediaControlPlugin.playerToShow(chosen: nil, shown: "YouTube", states: states, order: ["Spotify", "YouTube"]) == "YouTube")
    }

    @Test func keepsTheChosenPlayerEvenWhenPaused() {
        let states = ["Spotify": state("Spotify", playing: false), "YouTube": state("YouTube", playing: true)]
        #expect(MediaControlPlugin.playerToShow(chosen: "Spotify", shown: "YouTube", states: states, order: ["Spotify", "YouTube"]) == "Spotify")
    }

    @Test func fallsBackToTheFirstPlayerWhenNothingPlays() {
        let states = ["Spotify": state("Spotify", playing: false), "YouTube": state("YouTube", playing: false)]
        #expect(MediaControlPlugin.playerToShow(chosen: nil, shown: nil, states: states, order: ["YouTube", "Spotify"]) == "YouTube")
        #expect(MediaControlPlugin.playerToShow(chosen: nil, shown: nil, states: [:], order: []) == nil)
    }
}

struct ReceivedFileTests {
    @Test func marksReceivedFilesForGatekeeper() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-quarantine-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        SharePlugin.quarantine(url, from: "Pixel 9")
        let length = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        #expect(length > 0)
    }

    @Test func opensOnlyWebAndMailLinks() {
        #expect(SharePlugin.openableSchemes == ["http", "https", "mailto"])
    }
}
