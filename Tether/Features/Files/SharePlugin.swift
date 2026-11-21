//
//  SharePlugin.swift
//  Tether
//

import Foundation
import Combine
import AppKit
import UserNotifications
import UniformTypeIdentifiers

final class SharePlugin: ObservableObject, TetherPlugin, @unchecked Sendable {
    nonisolated static let shareRequestType = PacketType.shareRequest
    static let shareUpdateType = PacketType.shareRequestUpdate

    var supportedPacketTypes: [String] {
        [Self.shareRequestType, Self.shareUpdateType]
    }

    @Published private(set) var transfers: [TransferItem] = []

    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var pendingIncomingItems: [Int64: TransferItem] = [:]
    nonisolated(unsafe) private var activeUploaders: [UUID: PayloadUploader] = [:]
    /// Downloads in progress, by the packet that announced them.
    nonisolated(unsafe) private var activeDownloads: [Int64: PayloadDownloader.Handle] = [:]
    nonisolated private let sendQueue = DispatchQueue(label: "com.subhashh.tether.share.send", qos: .userInitiated)

    init() {}

    func onConnected(connection: DeviceConnection) {}
    func onDisconnected(connection: DeviceConnection) {}

    // MARK: - Packet Handling
    func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        let deviceName = connection.peerDeviceInfo?.deviceName ?? "Device"

        // 1. Text payload (no binary transfer)
        if let text = packet.string(for: "text"), !text.isEmpty {
            handleReceivedText(text, from: deviceName, deviceId: deviceId)
            return
        }

        // 2. URL payload (no binary transfer)
        if let urlString = packet.string(for: "url"), let url = URL(string: urlString) {
            handleReceivedURL(url, from: deviceName)
            return
        }

        // 3. File payload announcement
        if packet.payloadTransferInfo != nil, let size = packet.payloadSize {
            let cleanFilename = SafeFilename.sanitize(packet.string(for: "filename"))

            let item = TransferItem(
                deviceId: deviceId,
                deviceName: deviceName,
                filename: cleanFilename,
                totalBytes: size,
                transferredBytes: 0,
                direction: .incoming,
                status: .transferring,
                progress: 0.0,
                timestamp: Date()
            )

            lock.withLock {
                self.pendingIncomingItems[packet.id] = item
            }

            DispatchQueue.main.async {
                self.addTransfer(item)
            }
            TetherLog("[SharePlugin] Incoming file '\(cleanFilename)' (\(size) bytes) announced from \(deviceName)")
        }
    }

    func handlePayloadProgress(connection: DeviceConnection, packet: NetworkPacket, fraction: Double) {
        guard let itemId = lock.withLock({ pendingIncomingItems[packet.id]?.id }) else { return }
        DispatchQueue.main.async {
            guard let index = self.transfers.firstIndex(where: { $0.id == itemId }) else { return }
            self.transfers[index].progress = fraction
            self.transfers[index].transferredBytes = Int64(Double(self.transfers[index].totalBytes) * fraction)
        }
    }

    func handlePayloadFailure(connection: DeviceConnection, packet: NetworkPacket, error: Error) {
        guard let item = lock.withLock({ () -> TransferItem? in
            activeDownloads[packet.id] = nil
            return pendingIncomingItems.removeValue(forKey: packet.id)
        }) else { return }
        DispatchQueue.main.async {
            guard let index = self.transfers.firstIndex(where: { $0.id == item.id }) else { return }
            if case PayloadError.cancelled = error {
                self.transfers[index].status = .cancelled
            } else {
                self.transfers[index].status = .failed(error.localizedDescription)
            }
        }
    }

    /// The newest transfers are kept; older finished ones drop off, so the
    /// list doesn't grow for as long as Tether runs.
    private static let transferHistoryLimit = 50

    private func addTransfer(_ item: TransferItem) {
        transfers.insert(item, at: 0)
        guard transfers.count > Self.transferHistoryLimit,
              let oldestFinished = transfers.lastIndex(where: { $0.status != .transferring && $0.status != .queued }) else { return }
        transfers.remove(at: oldestFinished)
    }

    /// Remembers a download so it can be cancelled.
    nonisolated func track(_ handle: PayloadDownloader.Handle, forPacket packetId: Int64) {
        lock.withLock { activeDownloads[packetId] = handle }
    }

    func handlePayload(connection: DeviceConnection, packet: NetworkPacket, fileURL payloadURL: URL) {
        let deviceName = connection.peerDeviceInfo?.deviceName ?? "Device"
        let matchingItem = lock.withLock { () -> TransferItem? in
            activeDownloads[packet.id] = nil
            return pendingIncomingItems.removeValue(forKey: packet.id)
        }

        let filename = matchingItem?.filename ?? SafeFilename.sanitize(packet.string(for: "filename"))
        let downloadsDir = URL.downloadsDirectory
        let destinationURL = SafeFilename.uniqueURL(in: downloadsDir, for: filename)
        let itemId = matchingItem?.id

        do {
            try FileManager.default.moveItem(at: payloadURL, to: destinationURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            TetherLog("[SharePlugin] Saved \(size) bytes to \(destinationURL.path)")

            DispatchQueue.main.async {
                if let index = self.transfers.firstIndex(where: { $0.id == itemId }) {
                    self.transfers[index].status = .completed
                    self.transfers[index].progress = 1.0
                    self.transfers[index].transferredBytes = size
                    self.transfers[index].localURL = destinationURL
                }
            }

            postFileReceivedNotification(filename: destinationURL.lastPathComponent, from: deviceName, fileURL: destinationURL)
        } catch {
            TetherLog("[SharePlugin] Failed to move incoming file to \(destinationURL.path): \(error)")
            DispatchQueue.main.async {
                if let index = self.transfers.firstIndex(where: { $0.id == itemId }) {
                    self.transfers[index].status = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Outgoing File Transfers
    func sendFiles(_ urls: [URL], to connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        let deviceName = connection.peerDeviceInfo?.deviceName ?? "Device"

        // Looked up afresh for each file: a phone that reconnects mid-send
        // has a new connection.
        let service = TetherService.shared
        let currentConnection: @Sendable (String) -> DeviceConnection? = { service.connection(for: $0) }
        sendQueue.async { [weak self] in
            guard let self else { return }
            // Announce the files as one batch, as the official desktop client
            // does: every packet carries the batch's file count and total size.
            // Without them, KDE Connect on Android treats each file as a
            // separate legacy transfer, and in a multi-file send it kept only
            // the last one.
            let files = urls.compactMap { url -> (URL, Int64)? in
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                    TetherLog("[SharePlugin] Skipping unreadable file \(url.path)")
                    return nil
                }
                return (url, size.int64Value)
            }
            let batch = Batch(numberOfFiles: files.count, totalPayloadSize: files.reduce(0) { $0 + $1.1 })
            for (url, _) in files {
                self.sendSingleFileSynchronously(url: url, batch: batch, deviceId: deviceId, deviceName: deviceName,
                                                 connection: connection, currentConnection: currentConnection)
            }
        }
    }

    /// The whole multi-file send, announced in every file's packet.
    private struct Batch {
        let numberOfFiles: Int
        let totalPayloadSize: Int64
    }

    nonisolated private func sendSingleFileSynchronously(url: URL, batch: Batch, deviceId: String, deviceName: String,
                                                         connection: DeviceConnection,
                                                         currentConnection: (String) -> DeviceConnection?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            TetherLog("[SharePlugin] Failed to read attributes for file \(url.path)")
            return
        }

        let itemId = UUID()
        let filename = url.lastPathComponent
        let item = TransferItem(
            id: itemId,
            deviceId: deviceId,
            deviceName: deviceName,
            filename: filename,
            totalBytes: size,
            transferredBytes: 0,
            direction: .outgoing,
            status: .transferring,
            progress: 0.0,
            timestamp: Date(),
            localURL: url
        )

        DispatchQueue.main.async {
            self.addTransfer(item)
        }

        // Announced on the device's current connection, and once more if the
        // phone never picked it up: when it reconnects mid-send (switching
        // from Wi-Fi to Tailscale, say), an announcement on the old connection
        // is lost.
        var result: Result<Void, Error> = .failure(PayloadError.connectionTimeout)
        for attempt in 1...2 {
            let current = currentConnection(deviceId) ?? connection
            result = upload(url: url, attributes: attributes, batch: batch, itemId: itemId, size: size, connection: current)
            guard case .failure(PayloadError.connectionTimeout) = result, attempt == 1 else { break }
            TetherLog("[SharePlugin] \(deviceName) didn't pick up \(filename); announcing it again")
        }

        DispatchQueue.main.async {
            guard let index = self.transfers.firstIndex(where: { $0.id == itemId }) else { return }
            switch result {
            case .success:
                self.transfers[index].status = .completed
                self.transfers[index].progress = 1.0
                self.transfers[index].transferredBytes = size
                TetherLog("[SharePlugin] Finished sending \(filename) successfully.")
            case .failure(let error):
                self.transfers[index].status = .failed(error.localizedDescription)
                TetherLog("[SharePlugin] Failed sending \(filename): \(error)")
            }
        }
    }

    /// Offers one file on a payload port, announces it, and waits until the
    /// phone has fetched it or gave up.
    nonisolated private func upload(url: URL, attributes: [FileAttributeKey: Any], batch: Batch, itemId: UUID, size: Int64,
                        connection: DeviceConnection) -> Result<Void, Error> {
        let filename = url.lastPathComponent
        let uploader = PayloadUploader()
        lock.withLock {
            self.activeUploaders[itemId] = uploader
        }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Void, Error> = .failure(PayloadError.connectionTimeout)

        uploader.start(
            fileURL: url,
            expectedPeerFingerprint: connection.peerCertificateFingerprint,
            onReady: { offer in
                let creationDate = (attributes[.creationDate] as? Date) ?? Date()
                let modDate = (attributes[.modificationDate] as? Date) ?? Date()

                let packet = NetworkPacket(
                    type: Self.shareRequestType,
                    body: [
                        "filename": AnyCodable(filename),
                        "creationTime": AnyCodable(Int64(creationDate.timeIntervalSince1970 * 1000)),
                        "lastModified": AnyCodable(Int64(modDate.timeIntervalSince1970 * 1000)),
                        "open": AnyCodable(false),
                        "numberOfFiles": AnyCodable(batch.numberOfFiles),
                        "totalPayloadSize": AnyCodable(batch.totalPayloadSize)
                    ],
                    payloadSize: offer.size,
                    payloadTransferInfo: ["port": AnyCodable(Int(offer.port))]
                )

                connection.send(packet: packet)
                TetherLog("[SharePlugin] Sent share request announcement for \(filename) on port \(offer.port)")
            },
            onProgress: { [weak self] progress in
                DispatchQueue.main.async {
                    if let index = self?.transfers.firstIndex(where: { $0.id == itemId }) {
                        self?.transfers[index].progress = progress
                        self?.transfers[index].transferredBytes = Int64(Double(size) * progress)
                    }
                }
            },
            onComplete: { [weak self] result in
                self?.lock.withLock {
                    _ = self?.activeUploaders.removeValue(forKey: itemId)
                }
                outcome = result.map { _ in () }
                semaphore.signal()
            }
        )

        _ = semaphore.wait(timeout: .distantFuture)
        return outcome
    }

    /// Stops a file being sent or received.
    func cancelTransfer(id: UUID) {
        lock.withLock {
            if let uploader = activeUploaders.removeValue(forKey: id) {
                uploader.cancel()
            }
            if let packetId = pendingIncomingItems.first(where: { $0.value.id == id })?.key {
                activeDownloads.removeValue(forKey: packetId)?.cancel()
            }
        }
        DispatchQueue.main.async {
            if let index = self.transfers.firstIndex(where: { $0.id == id }) {
                self.transfers[index].status = .cancelled
            }
        }
    }

    func sendText(_ text: String, to connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: Self.shareRequestType,
            body: ["text": AnyCodable(text)]
        )
        connection.send(packet: packet)
        TetherLog("[SharePlugin] Sent text to \(connection.peerDeviceInfo?.deviceName ?? "Device")")
    }

    func sendURL(_ url: URL, to connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: Self.shareRequestType,
            body: ["url": AnyCodable(url.absoluteString)]
        )
        connection.send(packet: packet)
        TetherLog("[SharePlugin] Sent URL to \(connection.peerDeviceInfo?.deviceName ?? "Device")")
    }

    // MARK: - Helpers
    private func handleReceivedText(_ text: String, from deviceName: String, deviceId: String) {
        // Through the clipboard plugin, so it isn't sent straight back to
        // the phone as a clipboard change, and joins the phone's recent copies.
        TetherService.shared.clipboardPlugin.acceptShared(text, from: deviceId)
        TetherLog("[SharePlugin] Received shared text (\(text.count) characters) from \(deviceName)")

        let content = UNMutableNotificationContent()
        content.title = "Text Received from \(deviceName)"
        content.body = text
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Links a phone may open on this Mac. Anything else (a file: URL, or
    /// a scheme that starts an app doing something) is only shown.
    static let openableSchemes: Set<String> = ["http", "https", "mailto", "tel", "sms", "facetime", "maps", "geo"]

    private func handleReceivedURL(_ url: URL, from deviceName: String) {
        if let scheme = url.scheme?.lowercased(), Self.openableSchemes.contains(scheme) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        } else {
            TetherLog("[SharePlugin] Not opening a \(url.scheme ?? "schemeless") link from \(deviceName)")
        }
        TetherLog("[SharePlugin] Received a \(url.scheme ?? "schemeless") link from \(deviceName)")

        let content = UNMutableNotificationContent()
        content.title = "Link Received from \(deviceName)"
        content.body = url.absoluteString
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func postFileReceivedNotification(filename: String, from deviceName: String, fileURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = "File Received"
        content.body = "\(filename) from \(deviceName)"
        content.sound = .default
        content.userInfo = ["filePath": fileURL.path]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
