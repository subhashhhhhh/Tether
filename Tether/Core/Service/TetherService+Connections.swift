//
//  TetherService+Connections.swift
//  Tether
//
//  Connections: accepting and dialling, swapping a device's connection, handing packets and payloads to plugins.
//

import Foundation
import AppKit
import Network
import UserNotifications

extension TetherService {
    // MARK: - TCP Listener Delegate
    nonisolated func didAcceptConnection(socketFD: Int32, clientIP: String, clientPort: Int) {
        Task { @MainActor in
            let key = "in_\(clientIP):\(clientPort)"
            let connection = DeviceConnection(socketFD: socketFD, host: clientIP, port: clientPort)
            self.pendingConnections[key] = connection
            connection.delegate = self
            connection.connect()
        }
    }

    // MARK: - Connection Management
    func connect(to deviceId: String, host: String, port: Int) {
        guard connectedDevices[deviceId] == nil else { return }
        let key = "out_\(deviceId)"
        guard pendingConnections[key] == nil else { return }

        connectingDeviceIds.insert(deviceId)
        TetherLog("[TetherService] Connecting to \(deviceId) at \(host):\(port)")

        let connection = DeviceConnection(host: host, port: port, targetDeviceId: deviceId, isOutgoing: true)
        self.pendingConnections[key] = connection
        connection.delegate = self
        connection.connect()
    }

    // MARK: - DeviceConnectionDelegate
    nonisolated func deviceConnectionDidConnect(_ connection: DeviceConnection) {
        Task { @MainActor in
            guard let id = connection.peerDeviceInfo?.deviceId else { return }
            // Anything on the network can claim a device's ID. One that can't
            // prove it with the pinned certificate doesn't get to push out
            // the verified connection that's already there.
            if let current = self.connectedDevices[id], current !== connection,
               current.pairState == .paired, !current.isDisconnected, connection.pairState != .paired {
                TetherLog("[TetherService] Keeping the verified connection to \(id); refusing an unverified one from \(connection.host)")
                self.pendingConnections.removeValue(forKey: "in_\(connection.host):\(connection.port)")
                if self.pendingConnections["out_\(id)"] === connection {
                    self.pendingConnections.removeValue(forKey: "out_\(id)")
                }
                connection.disconnect()
                return
            }
            self.connectingDeviceIds.remove(id)
            self.pendingConnections.removeValue(forKey: "out_\(id)")
            self.pendingConnections.removeValue(forKey: "in_\(connection.host):\(connection.port)")

            self.connectionLock.withLock {
                self.activeDeviceIds.insert(id)
                self.activeHosts[id] = connection.host
                self.activeConnections[id] = connection
            }
            self.udpDiscovery.noteHost(connection.host, belongsTo: id)

            if let old = self.connectedDevices[id], old !== connection {
                TetherLog("[TetherService] Seamlessly replacing previous connection to \(id) with new active connection.")
                self.connectedDevices[id] = connection
                if let pairReq = self.incomingPairRequest, pairReq.info.deviceId == id {
                    self.incomingPairRequest = (connection: connection, info: pairReq.info)
                }
                if connection.pairState == .paired, self.activatedConnections.remove(ObjectIdentifier(old)) != nil {
                    // A swap, not a new arrival: plugins keep what they know.
                    self.activatedConnections.insert(ObjectIdentifier(connection))
                    for plugin in self.plugins {
                        plugin.onConnectionReplaced(old: old, new: connection)
                    }
                } else {
                    self.activatePlugins(for: connection)
                    self.deactivatePlugins(for: old)
                }
                old.disconnect()
                return
            }

            self.connectedDevices[id] = connection
            AwayLock.shared.phoneConnected(id)

            // Only a verified, paired device gets its plugins started.
            self.activatePlugins(for: connection)
            TetherLog("[TetherService] Connected to \(connection.peerDeviceInfo?.deviceName ?? id)")
        }
    }

    nonisolated func deviceConnectionDidDisconnect(_ connection: DeviceConnection, error: Error?) {
        Task { @MainActor in
            let id = connection.peerDeviceInfo?.deviceId ?? connection.targetDeviceId
            if let id = id {
                // An inbound attempt only claims this ID; its failure must not
                // cancel the outbound connection to the same device.
                if self.pendingConnections["out_\(id)"] === connection {
                    self.pendingConnections.removeValue(forKey: "out_\(id)")
                    self.connectingDeviceIds.remove(id)
                }
                if self.connectedDevices[id] === connection {
                    self.connectionLock.withLock {
                        self.activeDeviceIds.remove(id)
                        self.activeHosts[id] = nil
                        self.activeConnections[id] = nil
                    }
                    self.connectedDevices.removeValue(forKey: id)
                    self.deactivatePlugins(for: connection)
                    TetherLog("[TetherService] Disconnected from \(connection.peerDeviceInfo?.deviceName ?? id)")
                    // After a short drop the device is often back before its old connection times out.
                    if let heard = self.heardAt[id], Date().timeIntervalSince(heard) < 5 {
                        self.mdnsDiscovery.resolve(deviceId: id)
                    }
                    if let info = connection.peerDeviceInfo, info.deviceType == .phone, connection.pairState == .paired {
                        AwayLock.shared.phoneDisconnected(id, name: info.deviceName)
                    }
                    if connection.pairState == .paired {
                        // "Last seen" is when it left, not when it last connected.
                        self.trustStore.updateLastSeen(deviceId: id)
                        self.redial(id, lastHost: connection.host)
                    }
                }
            }
            self.pendingConnections.removeValue(forKey: "in_\(connection.host):\(connection.port)")

            // If we dialled out and never completed a handshake, announce ourselves
            // directly to the peer so it can dial back. Upstream does the same on any
            // connection error, and it is what makes pairing work on networks where
            // inbound connections to one of the two devices are blocked.
            if connection.isOutgoing, connection.peerDeviceInfo == nil {
                if let deviceId = connection.targetDeviceId {
                    TetherLog("[TetherService] Outgoing connection to \(connection.host) failed; inviting a reverse connection")
                    self.reachOut(to: deviceId, host: connection.host)
                } else {
                    let listenPort = self.tcpListener.activePort == 0
                        ? TCPListenerService.minPort
                        : self.tcpListener.activePort
                    TetherLog("[TetherService] Outgoing connection to \(connection.host) failed; inviting a reverse connection on port \(listenPort)")
                    self.udpDiscovery.sendDirectPresence(to: connection.host, tcpPort: Int(listenPort))
                }
            }
        }
    }

    nonisolated func deviceConnection(_ connection: DeviceConnection, didReceivePacket packet: NetworkPacket) {
        Task { @MainActor in
            for plugin in self.plugins {
                if plugin.supportedPacketTypes.contains(packet.type) {
                    plugin.handlePacket(connection: connection, packet: packet)
                }
            }
        }

        // A packet may announce a binary payload that follows on a separate TLS
        // connection. Fetch it in the background and deliver the bytes separately.
        // A file's size can be 0 (an empty file) or -1 (the phone didn't know it).
        guard let size = packet.payloadSize, size > 0 || size == -1 || (size == 0 && packet.type == SharePlugin.shareRequestType) else { return }
        // Notification artwork is small. Reject oversized announcements before
        // opening a payload socket or consuming disk space; text still arrives.
        if packet.type == PacketType.notification,
           size <= 0 || size > NotificationImages.maximumPayloadSize { return }
        guard let port = packet.payloadPort else {
            TetherLog("[TetherService] \(packet.type) announced \(size) bytes but no usable payload port: \(String(describing: packet.payloadTransferInfo))")
            return
        }
        // The phone sends a notification's picture again with each new
        // notification. One already stored is used as it is, as the desktop
        // app does; the phone gives up on the transfer after 10 s.
        if packet.type == PacketType.notification,
           let hash = packet.string(for: "payloadHash"), !hash.isEmpty,
           let deviceId = connection.peerDeviceInfo?.deviceId {
            Task { @MainActor in
                guard !self.notificationPlugin.hasImage(deviceId: deviceId, hash: hash) else { return }
                self.fetchPayload(of: packet, size: size, port: port, from: connection)
            }
            return
        }
        fetchPayload(of: packet, size: size, port: port, from: connection)
    }

    nonisolated func fetchPayload(of packet: NetworkPacket, size: Int64, port: UInt16, from connection: DeviceConnection) {
        TetherLog("[TetherService] \(packet.type) announced \(size) bytes; fetching from \(connection.host):\(port)")

        let handle = PayloadDownloader.download(
            host: connection.host,
            port: port,
            size: size,
            expectedPeerFingerprint: connection.peerCertificateFingerprint,
            onProgress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for plugin in self.plugins where plugin.supportedPacketTypes.contains(packet.type) {
                        plugin.handlePayloadProgress(connection: connection, packet: packet, fraction: fraction)
                    }
                }
            },
            completion: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let interested = self.plugins.filter { $0.supportedPacketTypes.contains(packet.type) }
                    switch result {
                    case .success(let fileURL):
                        for plugin in interested {
                            plugin.handlePayload(connection: connection, packet: packet, fileURL: fileURL)
                        }
                        // Plugins have moved or copied what they want to keep.
                        try? FileManager.default.removeItem(at: fileURL)
                    case .failure(let error):
                        TetherLog("[TetherService] Payload transfer failed for \(packet.type): \(error.localizedDescription)")
                        for plugin in interested {
                            plugin.handlePayloadFailure(connection: connection, packet: packet, error: error)
                        }
                    }
                }
            }
        )
        // Kept so a received file can be cancelled from the Files list.
        if packet.type == SharePlugin.shareRequestType {
            sharePlugin.track(handle, forPacket: packet.id)
        }
    }

    nonisolated func deviceConnection(_ connection: DeviceConnection, didUpdatePairState state: PairState) {
        Task { @MainActor in
            guard let info = connection.peerDeviceInfo else { return }
            TetherLog("[TetherService] Pair state updated to \(state) for \(info.deviceName)")

            if state == .requestedByPeer {
                self.incomingPairRequest = (connection: connection, info: info)
                self.showPairingRequestNotification(info: info, connection: connection)
            } else if state == .paired {
                if self.incomingPairRequest?.info.deviceId == info.deviceId {
                    self.incomingPairRequest = nil
                }
                self.dismissPairingRequestNotification(deviceId: info.deviceId)
                self.activatePlugins(for: connection)
            } else if state == .notPaired {
                if connection.hasCertificateMismatch {
                    self.warnCertificateMismatch(info)
                }
                if let req = self.incomingPairRequest, req.connection === connection {
                    self.incomingPairRequest = nil
                    self.dismissPairingRequestNotification(deviceId: info.deviceId)
                }
                self.deactivatePlugins(for: connection)
            }
        }
    }

    /// Starts plugins for a connection once: when it is the device's active
    /// connection and verified as paired. Both conditions can become true in
    /// either order, so both paths call this.
    func activatePlugins(for connection: DeviceConnection) {
        guard connection.pairState == .paired,
              let id = connection.peerDeviceInfo?.deviceId,
              connectedDevices[id] === connection,
              activatedConnections.insert(ObjectIdentifier(connection)).inserted else { return }
        for plugin in plugins {
            plugin.onConnected(connection: connection)
        }
    }

    func deactivatePlugins(for connection: DeviceConnection) {
        guard activatedConnections.remove(ObjectIdentifier(connection)) != nil else { return }
        for plugin in plugins {
            plugin.onDisconnected(connection: connection)
        }
    }
}
