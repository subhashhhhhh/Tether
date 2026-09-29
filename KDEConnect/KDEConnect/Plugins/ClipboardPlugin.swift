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
    private var timer: Timer?
    private var activeConnections: [DeviceConnection] = []

    public init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
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

        guard let text = NSPasteboard.general.string(forType: .string) else { return }

        // Suppress echo if this content originated from remote device
        if text == lastReceivedContent {
            return
        }

        if text == lastSentContent {
            return
        }

        lastSentContent = text
        print("[ClipboardPlugin] Local clipboard changed: \(text.prefix(30))... Broadcasting to paired devices")
        broadcastClipboard(content: text)
    }

    public func onConnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let paired = TrustStore.shared.pairedDevice(for: deviceId),
              paired.isClipboardSyncEnabled else {
            return
        }

        activeConnections.append(connection)

        // Send connect packet with initial clipboard content
        if let currentText = NSPasteboard.general.string(forType: .string), !currentText.isEmpty {
            let packet = NetworkPacket(
                type: "kdeconnect.clipboard.connect",
                body: [
                    "content": currentText,
                    "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
                ]
            )
            connection.send(packet: packet)
        }
    }

    public func onDisconnected(connection: DeviceConnection) {
        activeConnections.removeAll { $0 === connection }
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.clipboard" || packet.type == "kdeconnect.clipboard.connect" else { return }

        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let paired = TrustStore.shared.pairedDevice(for: deviceId),
              paired.isClipboardSyncEnabled else {
            return
        }

        guard let content = packet.string(for: "content") else { return }

        lastReceivedContent = content

        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            self.lastChangeCount = NSPasteboard.general.changeCount
            print("[ClipboardPlugin] Synced clipboard from \(connection.peerDeviceInfo?.deviceName ?? "Device"): \(content.prefix(30))...")
        }
    }

    public func broadcastClipboard(content: String) {
        let packet = NetworkPacket(
            type: "kdeconnect.clipboard",
            body: ["content": content]
        )
        for connection in activeConnections {
            if let deviceId = connection.peerDeviceInfo?.deviceId,
               let paired = TrustStore.shared.pairedDevice(for: deviceId),
               paired.isClipboardSyncEnabled {
                connection.send(packet: packet)
            }
        }
    }
}
