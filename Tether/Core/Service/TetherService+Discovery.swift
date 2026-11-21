//
//  TetherService+Discovery.swift
//  Tether
//
//  Finding devices: UDP and mDNS announcements, reaching out, redialling after a wake or a network change, and Tailscale.
//

import Foundation
import AppKit
import Network
import UserNotifications

extension TetherService {
    // MARK: - UDP Discovery Delegate
    nonisolated func isDeviceConnected(deviceId: String) -> Bool {
        connectionLock.withLock {
            activeDeviceIds.contains(deviceId)
        }
    }

    /// The device's current connection. A phone that reconnects (switching
    /// from Wi-Fi to Tailscale, say) gets a new one, so long-running work such
    /// as a multi-file send looks it up again instead of keeping the first.
    nonisolated func connection(for deviceId: String) -> DeviceConnection? {
        connectionLock.withLock { activeConnections[deviceId] }
    }

    nonisolated func connectedHosts() -> Set<String> {
        connectionLock.withLock {
            Set(activeHosts.values)
        }
    }

    nonisolated func didDiscoverDevice(host: String, port: Int, deviceInfo: DeviceInfo) {
        Task { @MainActor in
            self.discoveredDeviceEndpoints[deviceInfo.deviceId] = (host, port)

            if !self.discoveredDevices.contains(where: { $0.deviceId == deviceInfo.deviceId }) {
                self.discoveredDevices.append(deviceInfo)
            }

            if self.trustStore.isTrusted(deviceId: deviceInfo.deviceId) {
                self.announcedAt[deviceInfo.deviceId] = Date()
            }
            if let conn = self.connectedDevices[deviceInfo.deviceId], !conn.isDisconnected {
                return
            }

            if !self.connectingDeviceIds.contains(deviceInfo.deviceId) {
                // Only auto-connect if device is already paired in trustStore
                if self.trustStore.isTrusted(deviceId: deviceInfo.deviceId) {
                    self.connect(to: deviceInfo.deviceId, host: host, port: port)
                }
            }
        }
    }

    // MARK: - mDNS Discovery Delegate

    /// Unpaired devices get one announcement, as KDE Connect desktop does.
    nonisolated func didFindDevice(deviceId: String, host: String) {
        Task { @MainActor in
            if self.trustStore.isTrusted(deviceId: deviceId) {
                self.reachOut(to: deviceId, host: host)
            } else if !self.isDeviceConnected(deviceId: deviceId) {
                self.udpDiscovery.sendDirectPresence(to: host)
            }
        }
    }

    /// It may be back before we noticed it left; the disconnect path checks `heardAt`.
    nonisolated func didHear(deviceId: String) {
        Task { @MainActor in
            self.heardAt[deviceId] = Date()
            guard self.trustStore.isTrusted(deviceId: deviceId), !self.isDeviceConnected(deviceId: deviceId) else { return }
            TetherLog("[TetherService] Heard \(deviceId) in mDNS traffic; resolving")
            self.mdnsDiscovery.resolve(deviceId: deviceId)
        }
    }

    /// A phone isn't reachable for about a second after rejoining, and macOS can mark
    /// its address down for 20 s (net.link.ether.inet.host_down_time), hence the schedule.
    func reachOut(to deviceId: String, host: String) {
        let key = "\(deviceId)@\(host)"
        guard !isDeviceConnected(deviceId: deviceId), reachOutTasks[key] == nil else { return }
        TetherLog("[TetherService] Reaching out to \(deviceId) at \(host)")
        udpDiscovery.noteHost(host, belongsTo: deviceId)
        reachOutTasks[key] = Task {
            defer { reachOutTasks[key] = nil }
            var elapsed = 0.0
            // More than a second apart: the phone ignores a repeat from the
            // same address within one.
            for second in [0, 1.2, 2.5, 5, 10, 21, 30, 45] {
                try? await Task.sleep(for: .seconds(second - elapsed))
                elapsed = second
                guard !Task.isCancelled, !isDeviceConnected(deviceId: deviceId),
                      !pendingConnections.keys.contains(where: { $0.hasPrefix("in_\(host):") }) else { return }
                udpDiscovery.sendDirectPresence(to: host, throttled: false)
            }
            TetherLog("[TetherService] Sent last attempt to \(deviceId) at \(host) at 45 s")
        }
    }

    /// The broadcast timer doesn't run during sleep, so without this a phone
    /// waits out whatever was left of the interval. Wi-Fi takes a few seconds
    /// to come back, hence more than one announcement.
    func announceAfterWake() {
        redialPairedDevices()
        wakeTask?.cancel()
        wakeTask = Task {
            var elapsed = 0.0
            for second in [1.0, 4, 10] {
                try? await Task.sleep(for: .seconds(second - elapsed))
                elapsed = second
                guard !Task.isCancelled, isRunning else { return }
                udpDiscovery.broadcastPresence(routine: true)
            }
            refreshTailscale()
        }
    }

    /// After a wake or a network change: every paired device with a known
    /// address that isn't connected.
    func redialPairedDevices() {
        guard isRunning else { return }
        for deviceId in trustStore.pairedDevices.keys {
            guard let endpoint = discoveredDeviceEndpoints[deviceId] else { continue }
            redial(deviceId, lastHost: endpoint.host, restart: true)
        }
    }

    /// Dials a paired device that should still be there. An announcement only
    /// invites the phone to connect, and a phone that never saw the old
    /// connection close (this Mac's Wi-Fi dropped, or it slept) ignores it
    /// until its own side times out. Its listener answers straight away.
    func redial(_ deviceId: String, lastHost: String, restart: Bool = false) {
        guard isRunning, trustStore.isTrusted(deviceId: deviceId) else { return }
        if restart {
            redialTasks[deviceId]?.cancel()
        } else if redialTasks[deviceId] != nil {
            return
        }
        let task = Task {
            var elapsed = 0.0
            for second in [0.0, 2, 5, 10, 20, 30, 45, 60] {
                try? await Task.sleep(for: .seconds(second - elapsed))
                elapsed = second
                guard !Task.isCancelled, isRunning, trustStore.isTrusted(deviceId: deviceId),
                      !isDeviceConnected(deviceId: deviceId) else { break }
                let endpoint = discoveredDeviceEndpoints[deviceId]
                    ?? (host: lastHost, port: Int(UDPDiscoveryService.defaultPort))
                connect(to: deviceId, host: endpoint.host, port: endpoint.port)
            }
            if !Task.isCancelled { redialTasks[deviceId] = nil }
        }
        redialTasks[deviceId] = task
    }

    func refreshAdvertisement() {
        guard isRunning else { return }
        mdnsDiscovery.updateAdvertisement(DeviceIdentity.shared.toDeviceInfo(tcpPort: Int(tcpListener.activePort)))
    }


    // MARK: - Tailscale

    func startTailscaleDiscovery() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // Peers come and go as phones sleep or switch networks; a minute keeps
        // reconnection quick without spawning the CLI constantly.
        timer.schedule(deadline: .now(), repeating: .seconds(60), leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            // No CLI run every minute for a setting that's off; turning it
            // on is picked up on the next tick.
            guard TailscaleDiscovery.isEnabled else { return }
            Task { @MainActor in self?.refreshTailscale() }
        }
        timer.resume()
        tailscaleTimer = timer
    }

    /// Re-reads the tailnet and points discovery at the user's online phones.
    func refreshTailscale() {
        let discovery = udpDiscovery
        Task.detached(priority: .utility) {
            let enabled = TailscaleDiscovery.isEnabled
            let status = TailscaleDiscovery.currentStatus()
            let targets: Set<String>
            if enabled, case .running(_, let phones) = status {
                targets = Set(phones.map(\.ip))
            } else {
                targets = []
            }
            await MainActor.run { [weak self] in
                discovery.setTailscaleTargets(targets)
                if self?.tailscaleStatus != status { self?.tailscaleStatus = status }
            }
        }
    }
}
