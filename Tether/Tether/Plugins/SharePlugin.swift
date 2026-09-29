//
//  SharePlugin.swift
//  Tether
//

import Foundation
import Combine
import AppKit
import UserNotifications
import UniformTypeIdentifiers

public final class SharePlugin: ObservableObject, TetherPlugin, @unchecked Sendable {
    public static let shareRequestType = "kdeconnect.share.request"
    public static let shareUpdateType = "kdeconnect.share.request.update"

    public var supportedPacketTypes: [String] {
        [Self.shareRequestType, Self.shareUpdateType]
    }

    @Published public private(set) var transfers: [TransferItem] = []

    private let lock = NSLock()
    private var pendingIncomingItems: [Int64: TransferItem] = [:]
    private var activeUploaders: [UUID: PayloadUploader] = [:]
    private let sendQueue = DispatchQueue(label: "com.subhashh.tether.share.send", qos: .userInitiated)

    public init() {}

    public func onConnected(connection: DeviceConnection) {}
    public func onDisconnected(connection: DeviceConnection) {}

    // MARK: - Packet Handling
    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        let deviceName = connection.peerDeviceInfo?.deviceName ?? "Device"

        // 1. Text payload (no binary transfer)
        if let text = packet.string(for: "text"), !text.isEmpty {
            handleReceivedText(text, from: deviceName)
            return
        }

        // 2. URL payload (no binary transfer)
        if let urlString = packet.string(for: "url"), let url = URL(string: urlString) {
            handleReceivedURL(url, from: deviceName)
            return
        }

        // 3. File payload announcement
        if packet.payloadTransferInfo != nil, let size = packet.payloadSize {
            let rawFilename = packet.string(for: "filename") ?? "file"
            let cleanFilename = URL(fileURLWithPath: rawFilename).lastPathComponent

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
                self.transfers.insert(item, at: 0)
            }
            TetherLog("[SharePlugin] Incoming file '\(cleanFilename)' (\(size) bytes) announced from \(deviceName)")
        }
    }

    public func handlePayload(connection: DeviceConnection, packet: NetworkPacket, data: Data) {
        let deviceName = connection.peerDeviceInfo?.deviceName ?? "Device"

        var matchingItem: TransferItem?
        lock.withLock {
            matchingItem = self.pendingIncomingItems.removeValue(forKey: packet.id)
        }

        let filename = matchingItem?.filename ?? (packet.string(for: "filename") ?? "ReceivedFile")
        let destinationURL = uniqueDownloadsURL(for: filename)

        do {
            try data.write(to: destinationURL, options: .atomic)
            TetherLog("[SharePlugin] Successfully saved \(data.count) bytes to \(destinationURL.path)")

            let itemId = matchingItem?.id
            DispatchQueue.main.async {
                if let index = self.transfers.firstIndex(where: { $0.id == itemId }) {
                    self.transfers[index].status = .completed
                    self.transfers[index].progress = 1.0
                    self.transfers[index].transferredBytes = Int64(data.count)
                    self.transfers[index].localURL = destinationURL
                }
            }

            postFileReceivedNotification(filename: filename, from: deviceName, fileURL: destinationURL)
        } catch {
            TetherLog("[SharePlugin] Failed to write incoming file to \(destinationURL.path): \(error)")
            let itemId = matchingItem?.id
            DispatchQueue.main.async {
                if let index = self.transfers.firstIndex(where: { $0.id == itemId }) {
                    self.transfers[index].status = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Outgoing File Transfers
    public func sendFiles(_ urls: [URL], to connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        let deviceName = connection.peerDeviceInfo?.deviceName ?? "Device"

        sendQueue.async { [weak self] in
            guard let self else { return }
            for url in urls {
                self.sendSingleFileSynchronously(url: url, deviceId: deviceId, deviceName: deviceName, connection: connection)
            }
        }
    }

    private func sendSingleFileSynchronously(url: URL, deviceId: String, deviceName: String, connection: DeviceConnection) {
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
            self.transfers.insert(item, at: 0)
        }

        let uploader = PayloadUploader()
        lock.withLock {
            self.activeUploaders[itemId] = uploader
        }

        let semaphore = DispatchSemaphore(value: 0)

        uploader.start(
            fileURL: url,
            onReady: { offer in
                // Build the announcing packet
                let creationDate = (attributes[.creationDate] as? Date) ?? Date()
                let modDate = (attributes[.modificationDate] as? Date) ?? Date()

                let packet = NetworkPacket(
                    type: Self.shareRequestType,
                    body: [
                        "filename": AnyCodable(filename),
                        "creationTime": AnyCodable(Int64(creationDate.timeIntervalSince1970 * 1000)),
                        "lastModified": AnyCodable(Int64(modDate.timeIntervalSince1970 * 1000)),
                        "open": AnyCodable(false)
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
                guard let self else { return }
                self.lock.withLock {
                    _ = self.activeUploaders.removeValue(forKey: itemId)
                }
                DispatchQueue.main.async {
                    if let index = self.transfers.firstIndex(where: { $0.id == itemId }) {
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
                semaphore.signal()
            }
        )

        _ = semaphore.wait(timeout: .distantFuture)
    }

    public func cancelTransfer(id: UUID) {
        lock.withLock {
            if let uploader = activeUploaders.removeValue(forKey: id) {
                uploader.cancel()
            }
        }
        DispatchQueue.main.async {
            if let index = self.transfers.firstIndex(where: { $0.id == id }) {
                self.transfers[index].status = .cancelled
            }
        }
    }

    public func clearCompleted() {
        DispatchQueue.main.async {
            self.transfers.removeAll(where: { $0.status == .completed || $0.status == .cancelled })
        }
    }

    public func sendText(_ text: String, to connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: Self.shareRequestType,
            body: ["text": AnyCodable(text)]
        )
        connection.send(packet: packet)
        TetherLog("[SharePlugin] Sent text to \(connection.peerDeviceInfo?.deviceName ?? "Device")")
    }

    public func sendURL(_ url: URL, to connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: Self.shareRequestType,
            body: ["url": AnyCodable(url.absoluteString)]
        )
        connection.send(packet: packet)
        TetherLog("[SharePlugin] Sent URL to \(connection.peerDeviceInfo?.deviceName ?? "Device")")
    }

    // MARK: - Helpers
    private func handleReceivedText(_ text: String, from deviceName: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        TetherLog("[SharePlugin] Received shared text from \(deviceName): \(text.prefix(50))...")

        let content = UNMutableNotificationContent()
        content.title = "Text Received from \(deviceName)"
        content.body = text
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func handleReceivedURL(_ url: URL, from deviceName: String) {
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
        TetherLog("[SharePlugin] Received shared URL from \(deviceName): \(url.absoluteString)")

        let content = UNMutableNotificationContent()
        content.title = "Link Received from \(deviceName)"
        content.body = url.absoluteString
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func uniqueDownloadsURL(for filename: String) -> URL {
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var targetURL = downloadsDir.appendingPathComponent(filename)

        let baseName = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1

        while FileManager.default.fileExists(atPath: targetURL.path) {
            let newName: String
            if ext.isEmpty {
                newName = "\(baseName) (\(counter))"
            } else {
                newName = "\(baseName) (\(counter)).\(ext)"
            }
            targetURL = downloadsDir.appendingPathComponent(newName)
            counter += 1
        }
        return targetURL
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
