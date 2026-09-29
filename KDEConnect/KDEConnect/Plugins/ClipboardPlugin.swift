//
//  ClipboardPlugin.swift
//  KDEConnect
//

import AppKit
import Foundation

public final class ClipboardPlugin: KDEConnectPlugin, @unchecked Sendable {
    public let supportedPacketTypes = [
        "kdeconnect.clipboard",
        "kdeconnect.clipboard.connect"
    ]

    private var lastChangeCount: Int = 0
    private var lastReceivedContent: String = ""
    private var lastSentContent: String = ""
    private var lastLocalClipboardTimestamp: Int64 = 0
    private var timer: Timer?
    private var activeConnections: [DeviceConnection] = []
    private let lock = NSLock()

    public init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
        if let initial = NSPasteboard.general.string(forType: .string), !initial.isEmpty {
            self.lastSentContent = initial
        }
        startMonitoring()
    }

    private func startMonitoring() {
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkPasteboard()
            }
        }
    }

    private func checkPasteboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }

        // Suppress echo if this content originated from remote device or was already sent
        if text == lastReceivedContent || text == lastSentContent {
            return
        }

        lastSentContent = text
        lastLocalClipboardTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        KDLog("[ClipboardPlugin] Local clipboard changed: \(text.prefix(30))... Broadcasting to paired devices")
        broadcastClipboard(content: text)
    }

    public func onConnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let paired = TrustStore.shared.pairedDevice(for: deviceId),
              paired.isClipboardSyncEnabled else {
            return
        }

        lock.withLock {
            guard !activeConnections.contains(where: { $0 === connection }) else { return }
            activeConnections.append(connection)
        }

        // Only send clipboard.connect if we actually have a local clipboard copied after app started
        if lastLocalClipboardTimestamp > 0,
           let currentText = NSPasteboard.general.string(forType: .string),
           !currentText.isEmpty {
            lastSentContent = currentText
            let packet = NetworkPacket(
                type: "kdeconnect.clipboard.connect",
                body: [
                    "content": currentText,
                    "timestamp": lastLocalClipboardTimestamp
                ]
            )
            connection.send(packet: packet)
        }
    }

    public func onDisconnected(connection: DeviceConnection) {
        lock.withLock {
            activeConnections.removeAll { $0 === connection }
        }
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.clipboard" || packet.type == "kdeconnect.clipboard.connect" else { return }

        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let paired = TrustStore.shared.pairedDevice(for: deviceId),
              paired.isClipboardSyncEnabled else {
            return
        }

        guard let content = packet.string(for: "content") else { return }

        // If it's a connect packet, verify timestamp to prevent overwriting with stale content
        if packet.type == "kdeconnect.clipboard.connect" {
            let packetTime = packet.int64(for: "timestamp", default: 0)
            if packetTime > 0 && packetTime < lastLocalClipboardTimestamp {
                KDLog("[ClipboardPlugin] Ignoring connect packet with older timestamp: \(packetTime) vs \(lastLocalClipboardTimestamp)")
                return
            }
        }

        guard content != lastReceivedContent && content != lastSentContent else { return }

        lastReceivedContent = content
        lastSentContent = content
        if packet.type == "kdeconnect.clipboard.connect" {
            let packetTime = packet.int64(for: "timestamp", default: 0)
            if packetTime > 0 {
                lastLocalClipboardTimestamp = packetTime
            }
        } else {
            lastLocalClipboardTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        }

        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            self.lastChangeCount = NSPasteboard.general.changeCount
            KDLog("[ClipboardPlugin] Synced clipboard from \(connection.peerDeviceInfo?.deviceName ?? "Device"): \(content.prefix(30))...")
        }
    }

    public func broadcastClipboard(content: String) {
        let packet = NetworkPacket(
            type: "kdeconnect.clipboard",
            body: ["content": content]
        )
        let targets: [DeviceConnection] = lock.withLock { activeConnections }
        for connection in targets {
            if let deviceId = connection.peerDeviceInfo?.deviceId,
               let paired = TrustStore.shared.pairedDevice(for: deviceId),
               paired.isClipboardSyncEnabled {
                connection.send(packet: packet)
            }
        }
    }
}
