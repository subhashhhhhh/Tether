//
//  TetherService.swift
//  Tether
//

import Foundation
import AppKit
import Combine
import Network
import SwiftUI
import UserNotifications

@MainActor
final class TetherService: ObservableObject, UDPDiscoveryDelegate, MDNSDiscoveryDelegate, TCPListenerDelegate, DeviceConnectionDelegate {
    static let shared = TetherService()

    @Published var isRunning: Bool = false
    @Published var discoveredDevices: [DeviceInfo] = []
    /// When each discovered device last announced itself.
    var lastDiscovered: [String: Date] = [:]
    /// An unpaired device not heard from in this long leaves the Nearby list.
    static let discoveryLifetime: TimeInterval = 10 * 60

    /// Drops unpaired devices that stopped announcing, so the list doesn't
    /// keep every phone that ever passed through the network.
    func pruneDiscoveredDevices() {
        let cutoff = Date().addingTimeInterval(-Self.discoveryLifetime)
        let stale = discoveredDevices.filter { device in
            !trustStore.isTrusted(deviceId: device.deviceId) && (lastDiscovered[device.deviceId] ?? .distantPast) < cutoff
        }
        guard !stale.isEmpty else { return }
        let ids = Set(stale.map(\.deviceId))
        discoveredDevices.removeAll { ids.contains($0.deviceId) }
        for id in ids { lastDiscovered[id] = nil }
    }
    @Published var connectedDevices: [String: DeviceConnection] = [:]
    @Published var incomingPairRequest: (connection: DeviceConnection, info: DeviceInfo)?
    @Published var tailscaleStatus: TailscaleStatus = .notInstalled

    let trustStore = TrustStore.shared
    let pingPlugin = PingPlugin()
    let clipboardPlugin = ClipboardPlugin()
    let notificationPlugin = NotificationPlugin()
    let batteryPlugin = BatteryPlugin()
    let mediaControlPlugin = MediaControlPlugin()
    let findMyPhonePlugin = FindMyPhonePlugin()
    let lockDevicePlugin = LockDevicePlugin()
    let connectivityReportPlugin = ConnectivityReportPlugin()
    let telephonyPlugin = TelephonyPlugin()
    let remoteVolumePlugin = RemoteVolumePlugin()
    let macVolumePlugin = MacVolumePlugin()
    let macMediaPlugin = MacMediaPlugin()
    let sharePlugin = SharePlugin()
    let mousepadPlugin = MousepadPlugin()
    let presenterPlugin = PresenterPlugin()
    let smsPlugin = SMSPlugin()
    let contactsPlugin = ContactsPlugin()
    let runCommandPlugin = RunCommandPlugin()
    let sftpPlugin = SftpPlugin()

    let udpDiscovery = UDPDiscoveryService()
    let mdnsDiscovery = MDNSDiscovery()
    var pairedDevicesObserver: AnyCancellable?
    var heardAt: [String: Date] = [:]
    /// When each device last announced itself over UDP, connected or not.
    var announcedAt: [String: Date] = [:]
    var wakeObserver: AnyCancellable?
    var wakeTask: Task<Void, Never>?
    var redialTasks: [String: Task<Void, Never>] = [:]
    var pathMonitor: NWPathMonitor?
    var reachOutTasks: [String: Task<Void, Never>] = [:]
    var tailscaleTimer: DispatchSourceTimer?
    var warnedMismatches: Set<String> = []
    let tcpListener = TCPListenerService()
    var discoveredDeviceEndpoints: [String: (host: String, port: Int)] = [:]
    var connectingDeviceIds = Set<String>()
    var pendingConnections: [String: DeviceConnection] = [:]
    var plugins: [TetherPlugin] = []
    nonisolated let connectionLock = NSLock()
    nonisolated(unsafe) var activeDeviceIds = Set<String>()
    /// Address of each connected device, so discovery doesn't re-announce to it.
    nonisolated(unsafe) var activeHosts: [String: String] = [:]
    /// The live connection to each device, readable from any thread.
    nonisolated(unsafe) var activeConnections: [String: DeviceConnection] = [:]
    /// Connections whose plugins have been started, so each starts exactly once.
    var activatedConnections = Set<ObjectIdentifier>()

    init() {
        self.plugins = [
            pingPlugin,
            clipboardPlugin,
            notificationPlugin,
            batteryPlugin,
            mediaControlPlugin,
            findMyPhonePlugin,
            lockDevicePlugin,
            connectivityReportPlugin,
            telephonyPlugin,
            remoteVolumePlugin,
            macVolumePlugin,
            macMediaPlugin,
            sharePlugin,
            mousepadPlugin,
            presenterPlugin,
            smsPlugin,
            contactsPlugin,
            runCommandPlugin,
            sftpPlugin
        ]
        udpDiscovery.delegate = self
        mdnsDiscovery.delegate = self
        tcpListener.delegate = self
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        PhoneNowPlaying.shared.start()
        // Nothing is downloading yet, so anything here was cut off when
        // Tether last quit or crashed mid-transfer.
        try? FileManager.default.removeItem(at: PayloadDownloader.incomingDirectory)

        tcpListener.start()
        udpDiscovery.start()
        mdnsDiscovery.start(advertising: DeviceIdentity.shared.toDeviceInfo(tcpPort: Int(tcpListener.activePort)))
        pairedDevicesObserver = trustStore.$pairedDevices.sink { [weak self] devices in
            self?.mdnsDiscovery.setPairedDeviceIds(Set(devices.keys))
            self?.udpDiscovery.setPairedDeviceIds(Set(devices.keys))
        }
        startTailscaleDiscovery()
        wakeObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.announceAfterWake() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.redialPairedDevices() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        TetherLog("[TetherService] Service started successfully.")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        udpDiscovery.stop()
        mdnsDiscovery.stop()
        pairedDevicesObserver = nil
        for task in reachOutTasks.values {
            task.cancel()
        }
        reachOutTasks.removeAll()
        wakeObserver = nil
        wakeTask?.cancel()
        wakeTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for task in redialTasks.values {
            task.cancel()
        }
        redialTasks.removeAll()
        tcpListener.stop()
        tailscaleTimer?.cancel()
        tailscaleTimer = nil

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
        connectionLock.withLock {
            activeDeviceIds.removeAll()
            activeHosts.removeAll()
            activeConnections.removeAll()
        }
        TetherLog("[TetherService] Service stopped.")
    }

    // MARK: - Remote device actions

    func ringPhone(_ deviceId: String) {
        guard let conn = connectedDevices[deviceId] else { return }
        findMyPhonePlugin.ring(deviceId: deviceId, connection: conn)
    }

    func lockPhone(_ deviceId: String) {
        guard let conn = connectedDevices[deviceId] else { return }
        lockDevicePlugin.lock(connection: conn)
    }

    func mediaAction(_ action: String, deviceId: String) {
        guard let conn = connectedDevices[deviceId] else { return }
        mediaControlPlugin.sendAction(action, connection: conn)
    }

    /// KDE Connect for Android takes volume changes only through its media
    /// controls (`kdeconnect.mpris.request` with `setVolume`), applied to the
    /// active player's stream, so this needs a media app with a session.
    /// `systemvolume` is the other direction on Android (the phone controlling a
    /// computer); only desktops report sinks for it.
    func setPhoneVolume(_ volume: Int, deviceId: String) {
        guard let conn = connectedDevices[deviceId] else { return }
        if !(mediaControlPlugin.players[deviceId] ?? []).isEmpty {
            mediaControlPlugin.setVolume(volume, connection: conn)
        } else if let sink = remoteVolumePlugin.sinks[deviceId]?.first(where: { $0.enabled })
                    ?? remoteVolumePlugin.sinks[deviceId]?.first {
            remoteVolumePlugin.setVolume(sinkName: sink.name, volume: volume, connection: conn)
        }
    }

    /// `thorough` announces to every candidate, connected phones included, and
    /// sweeps the local subnet, as the "Look for Devices" buttons do. Otherwise
    /// it's the routine broadcast, which leaves connected phones alone: KDE Connect
    /// on Android answers any announcement by opening a new connection and
    /// dropping its current one.
    func refreshDiscovery(thorough: Bool = true) {
        if thorough {
            udpDiscovery.broadcastPresence(sweepSubnet: true)
        } else {
            udpDiscovery.broadcastPresence(routine: true)
        }
        refreshTailscale()
    }

    /// Adds a peer by IPv4 address or host name (including Tailscale MagicDNS
    /// names). Returns false if the name doesn't resolve.
    func addManualPeer(address: String) async -> Bool {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = await Task.detached { HostResolver.ipv4(for: host) }.value
        guard let ip else {
            TetherLog("[TetherService] Could not resolve \(host)")
            return false
        }
        TetherLog("[TetherService] Adding manual peer \(host) (\(ip))")
        udpDiscovery.addKnownTarget(ip: ip)
        udpDiscovery.sendDirectPresence(to: ip)
        udpDiscovery.broadcastPresence()
        return true
    }

    func sendFiles(_ urls: [URL], to deviceId: String) {
        guard let conn = connectedDevices[deviceId] else { return }
        sharePlugin.sendFiles(urls, to: conn)
    }

    func sendText(_ text: String, to deviceId: String) {
        guard let conn = connectedDevices[deviceId] else { return }
        sharePlugin.sendText(text, to: conn)
    }

    func sendURL(_ url: URL, to deviceId: String) {
        guard let conn = connectedDevices[deviceId] else { return }
        sharePlugin.sendURL(url, to: conn)
    }

}
