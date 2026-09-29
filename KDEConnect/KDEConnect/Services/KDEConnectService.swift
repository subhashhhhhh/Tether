//
//  KDEConnectService.swift
//  KDEConnect
//

import Foundation
import Combine
import SwiftUI

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

            // Immediately initiate connection to establish link so phone sees Mac as Available
            if self.connectedDevices[deviceInfo.deviceId] == nil && !self.connectingDeviceIds.contains(deviceInfo.deviceId) {
                self.connect(to: deviceInfo.deviceId, host: host, port: port)
            }
        }
    }

    // MARK: - TCP Listener Delegate
    nonisolated public func didAcceptConnection(socketFD: Int32, clientIP: String, clientPort: Int) {
        Task { @MainActor in
            let connection = DeviceConnection(socketFD: socketFD, host: clientIP, port: clientPort)
            connection.delegate = self
            connection.connect()
        }
    }

    // MARK: - Connection Management
    public func connect(to deviceId: String, host: String, port: Int) {
        guard connectedDevices[deviceId] == nil else { return }
        connectingDeviceIds.insert(deviceId)
        KDLog("[KDEConnectService] Connecting to \(deviceId) at \(host):\(port)")

        let connection = DeviceConnection(host: host, port: port, targetDeviceId: deviceId, isOutgoing: true)
        connection.delegate = self
        connection.connect()
    }

    // MARK: - DeviceConnectionDelegate
    nonisolated public func deviceConnectionDidConnect(_ connection: DeviceConnection) {
        Task { @MainActor in
            guard let id = connection.peerDeviceInfo?.deviceId else { return }
            self.connectingDeviceIds.remove(id)

            if let old = self.connectedDevices[id], old !== connection {
                old.disconnect()
            }
            self.connectedDevices[id] = connection

            for plugin in self.plugins {
                plugin.onConnected(connection: connection)
            }
            KDLog("[KDEConnectService] Connected to \(connection.peerDeviceInfo?.deviceName ?? id)")
        }
    }

    nonisolated public func deviceConnectionDidDisconnect(_ connection: DeviceConnection, error: Error?) {
        Task { @MainActor in
            let id = connection.peerDeviceInfo?.deviceId ?? connection.targetDeviceId
            if let id = id {
                self.connectingDeviceIds.remove(id)
                if self.connectedDevices[id] === connection {
                    self.connectedDevices.removeValue(forKey: id)
                }
            }

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
            } else if state == .paired {
                if self.incomingPairRequest?.info.deviceId == info.deviceId {
                    self.incomingPairRequest = nil
                }
                for plugin in self.plugins {
                    plugin.onConnected(connection: connection)
                }
            } else if state == .notPaired {
                if self.incomingPairRequest?.info.deviceId == info.deviceId {
                    self.incomingPairRequest = nil
                }
            }
        }
    }

    // MARK: - Pairing & User Actions
    public func requestPair(with deviceInfo: DeviceInfo) {
        if let conn = connectedDevices[deviceInfo.deviceId] {
            conn.requestPairing()
        } else if let endpoint = discoveredDeviceEndpoints[deviceInfo.deviceId] {
            let connection = DeviceConnection(host: endpoint.host, port: endpoint.port, targetDeviceId: deviceInfo.deviceId, isOutgoing: true)
            connection.pendingPairingRequest = true
            connection.delegate = self
            connectingDeviceIds.insert(deviceInfo.deviceId)
            connection.connect()
        }
    }

    public func acceptIncomingPairRequest() {
        incomingPairRequest?.connection.acceptPairing()
        incomingPairRequest = nil
    }

    public func rejectIncomingPairRequest() {
        incomingPairRequest?.connection.rejectPairing()
        incomingPairRequest = nil
    }

    public func unpair(deviceId: String) {
        connectedDevices[deviceId]?.unpair()
        trustStore.remove(deviceId: deviceId)
    }

    public func sendPing(to deviceId: String) {
        if let conn = connectedDevices[deviceId] {
            pingPlugin.sendPing(to: conn)
        }
    }
}
