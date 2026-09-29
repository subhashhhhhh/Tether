//
//  KDEConnectService.swift
//  KDEConnect
//

import Foundation
import Combine
import SwiftUI
import UserNotifications

@MainActor
public final class KDEConnectService: ObservableObject, UDPDiscoveryDelegate, TCPListenerDelegate, DeviceConnectionDelegate {
    public static let shared = KDEConnectService()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var discoveredDevices: [DeviceInfo] = []
    @Published public private(set) var connectedDevices: [String: DeviceConnection] = [:]
    @Published public var incomingPairRequest: (connection: DeviceConnection, info: DeviceInfo)?

    public let trustStore = TrustStore.shared
    public let pingPlugin = PingPlugin()
    public let clipboardPlugin = ClipboardPlugin()
    public let notificationPlugin = NotificationPlugin()
    public let batteryPlugin = BatteryPlugin()

    private let udpDiscovery = UDPDiscoveryService()
    private let tcpListener = TCPListenerService()
    private var discoveredDeviceEndpoints: [String: (host: String, port: Int)] = [:]
    private var connectingDeviceIds = Set<String>()
    private var pendingConnections: [String: DeviceConnection] = [:]
    private var plugins: [KDEConnectPlugin] = []

    private init() {
        self.plugins = [pingPlugin, clipboardPlugin, notificationPlugin, batteryPlugin]
        udpDiscovery.delegate = self
        tcpListener.delegate = self
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        tcpListener.start()
        udpDiscovery.start()
        KDLog("[KDEConnectService] Service started successfully.")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        udpDiscovery.stop()
        tcpListener.stop()

        for conn in connectedDevices.values {
            conn.disconnect()
        }
        for conn in pendingConnections.values {
            conn.disconnect()
        }
        pendingConnections.removeAll()
        connectedDevices.removeAll()
        discoveredDevices.removeAll()
        connectingDeviceIds.removeAll()
        KDLog("[KDEConnectService] Service stopped.")
    }

    // MARK: - UDP Discovery Delegate
    nonisolated public func didDiscoverDevice(host: String, port: Int, deviceInfo: DeviceInfo) {
        Task { @MainActor in
            self.discoveredDeviceEndpoints[deviceInfo.deviceId] = (host, port)

            if !self.discoveredDevices.contains(where: { $0.deviceId == deviceInfo.deviceId }) {
                self.discoveredDevices.append(deviceInfo)
            }

            if let conn = self.connectedDevices[deviceInfo.deviceId], !conn.isDisconnected {
                return
            }

            if !self.connectingDeviceIds.contains(deviceInfo.deviceId) {
                self.connect(to: deviceInfo.deviceId, host: host, port: port)
            }
        }
    }

    // MARK: - TCP Listener Delegate
    nonisolated public func didAcceptConnection(socketFD: Int32, clientIP: String, clientPort: Int) {
        Task { @MainActor in
            let key = "in_\(clientIP):\(clientPort)"
            let connection = DeviceConnection(socketFD: socketFD, host: clientIP, port: clientPort)
            self.pendingConnections[key] = connection
            connection.delegate = self
            connection.connect()
        }
    }

    // MARK: - Connection Management
    public func connect(to deviceId: String, host: String, port: Int) {
        guard connectedDevices[deviceId] == nil else { return }
        let key = "out_\(deviceId)"
        guard pendingConnections[key] == nil else { return }

        connectingDeviceIds.insert(deviceId)
        KDLog("[KDEConnectService] Connecting to \(deviceId) at \(host):\(port)")

        let connection = DeviceConnection(host: host, port: port, targetDeviceId: deviceId, isOutgoing: true)
        self.pendingConnections[key] = connection
        connection.delegate = self
        connection.connect()
    }

    // MARK: - DeviceConnectionDelegate
    nonisolated public func deviceConnectionDidConnect(_ connection: DeviceConnection) {
        Task { @MainActor in
            guard let id = connection.peerDeviceInfo?.deviceId else { return }
            self.connectingDeviceIds.remove(id)
            self.pendingConnections.removeValue(forKey: "out_\(id)")
            self.pendingConnections.removeValue(forKey: "in_\(connection.host):\(connection.port)")

            if let old = self.connectedDevices[id], old !== connection {
                // If old connection is actively awaiting pairing confirmation, do NOT drop it!
                if old.pairState == .requested && !old.isDisconnected {
                    KDLog("[KDEConnectService] Active connection is awaiting pairing response. Disconnecting redundant duplicate connection.")
                    connection.disconnect()
                    return
                }

                // If old connection is already paired and alive, keep it
                if old.pairState == .paired && !old.isDisconnected {
                    KDLog("[KDEConnectService] Active connection is already paired and healthy. Disconnecting redundant duplicate connection.")
                    connection.disconnect()
                    return
                }

                old.disconnect()
            }
            self.connectedDevices[id] = connection

            // IMPORTANT: Only activate plugins if the device is already paired!
            if connection.pairState == .paired {
                for plugin in self.plugins {
                    plugin.onConnected(connection: connection)
                }
            }
            KDLog("[KDEConnectService] Connected to \(connection.peerDeviceInfo?.deviceName ?? id)")
        }
    }

    nonisolated public func deviceConnectionDidDisconnect(_ connection: DeviceConnection, error: Error?) {
        Task { @MainActor in
            let id = connection.peerDeviceInfo?.deviceId ?? connection.targetDeviceId
            if let id = id {
                self.connectingDeviceIds.remove(id)
                self.pendingConnections.removeValue(forKey: "out_\(id)")
                if self.connectedDevices[id] === connection {
                    self.connectedDevices.removeValue(forKey: id)
                }
            }
            self.pendingConnections.removeValue(forKey: "in_\(connection.host):\(connection.port)")

            for plugin in self.plugins {
                plugin.onDisconnected(connection: connection)
            }
            KDLog("[KDEConnectService] Disconnected from \(connection.peerDeviceInfo?.deviceName ?? id ?? "unknown")")
        }
    }

    nonisolated public func deviceConnection(_ connection: DeviceConnection, didReceivePacket packet: NetworkPacket) {
        Task { @MainActor in
            for plugin in self.plugins {
                if plugin.supportedPacketTypes.contains(packet.type) {
                    plugin.handlePacket(connection: connection, packet: packet)
                }
            }
        }
    }

    nonisolated public func deviceConnection(_ connection: DeviceConnection, didUpdatePairState state: PairState) {
        Task { @MainActor in
            guard let info = connection.peerDeviceInfo else { return }
            KDLog("[KDEConnectService] Pair state updated to \(state) for \(info.deviceName)")

            if state == .requestedByPeer {
                self.incomingPairRequest = (connection: connection, info: info)
                self.showPairingRequestNotification(info: info, connection: connection)
            } else if state == .paired {
                if self.incomingPairRequest?.info.deviceId == info.deviceId {
                    self.incomingPairRequest = nil
                }
                self.dismissPairingRequestNotification(deviceId: info.deviceId)
                for plugin in self.plugins {
                    plugin.onConnected(connection: connection)
                }
            } else if state == .notPaired {
                if self.incomingPairRequest?.info.deviceId == info.deviceId {
                    self.incomingPairRequest = nil
                }
                self.dismissPairingRequestNotification(deviceId: info.deviceId)
                for plugin in self.plugins {
                    plugin.onDisconnected(connection: connection)
                }
            }
        }
    }

    // MARK: - Pairing & User Actions
    public func requestPair(with deviceInfo: DeviceInfo) {
        if let conn = connectedDevices[deviceInfo.deviceId], !conn.isDisconnected {
            conn.requestPairing()
        } else if let endpoint = discoveredDeviceEndpoints[deviceInfo.deviceId] {
            let key = "out_\(deviceInfo.deviceId)"
            let connection = DeviceConnection(host: endpoint.host, port: endpoint.port, targetDeviceId: deviceInfo.deviceId, isOutgoing: true)
            connection.pendingPairingRequest = true
            connection.delegate = self
            self.pendingConnections[key] = connection
            connectingDeviceIds.insert(deviceInfo.deviceId)
            connection.connect()
        }
    }

    public func acceptIncomingPairRequest() {
        guard let pairReq = incomingPairRequest else { return }
        dismissPairingRequestNotification(deviceId: pairReq.info.deviceId)
        pairReq.connection.acceptPairing()
        incomingPairRequest = nil
    }

    public func rejectIncomingPairRequest() {
        guard let pairReq = incomingPairRequest else { return }
        dismissPairingRequestNotification(deviceId: pairReq.info.deviceId)
        pairReq.connection.rejectPairing()
        incomingPairRequest = nil
    }

    public func unpair(deviceId: String) {
        dismissPairingRequestNotification(deviceId: deviceId)
        if let conn = connectedDevices[deviceId] {
            conn.unpair()
            for plugin in self.plugins {
                plugin.onDisconnected(connection: conn)
            }
            connectedDevices.removeValue(forKey: deviceId)
        }
        trustStore.remove(deviceId: deviceId)
    }

    public func sendPing(to deviceId: String) {
        if let conn = connectedDevices[deviceId] {
            pingPlugin.sendPing(to: conn)
        }
    }

    public func refreshDiscovery() {
        udpDiscovery.broadcastPresence()
    }

    // MARK: - Notifications
    private func showPairingRequestNotification(info: DeviceInfo, connection: DeviceConnection) {
        let content = UNMutableNotificationContent()
        content.title = "Pairing Request"
        content.subtitle = info.deviceName
        if let fp = connection.peerCertificateFingerprint {
            content.body = "Verification Key:\n\(fp.prefix(23))..."
        } else {
            content.body = "\(info.deviceName) wants to pair with this Mac."
        }
        content.sound = .default
        content.categoryIdentifier = "KDE_PAIR_REQUEST_CATEGORY"
        content.userInfo = ["deviceId": info.deviceId]

        let request = UNNotificationRequest(
            identifier: "kde_pair_\(info.deviceId)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                KDLog("[KDEConnectService] Failed to post pairing notification: \(error)")
            }
        }
    }

    private func dismissPairingRequestNotification(deviceId: String) {
        let id = "kde_pair_\(deviceId)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
