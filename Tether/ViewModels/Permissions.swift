//
//  Permissions.swift
//  Tether
//
//  What macOS lets Tether do, in one place: the main window, the first-run
//  page and Settings › Permissions all read this. Each status is read from
//  the system's own API and kept current while Tether runs, so turning
//  something on in System Settings shows here without a restart.
//

import AppKit
import ApplicationServices
import Network
import Observation
import UserNotifications

@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    enum Status: Equatable {
        case allowed
        /// Turned off, or never asked where the system can't tell the two apart.
        case off
        case notAsked
        /// The system hasn't said yet, or can't say now (no network, say).
        case unknown
    }

    private(set) var notifications: Status = .unknown
    private(set) var accessibility: Status = .unknown
    private(set) var localNetwork: Status = .unknown

    @ObservationIgnored private var localNetworkProbe: NWConnection?
    @ObservationIgnored private var hasAskedForAccessibility = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-TetherDemoData") {
            notifications = .allowed
            accessibility = .allowed
            localNetwork = .allowed
            return
        }
        #endif
        refresh()
        // Back from System Settings.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        })
        // Posted when any app's Accessibility access changes. The new value
        // can take a moment to read back.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { Permissions.shared.refreshAccessibility() }
            }
        })
    }

    func refresh() {
        refreshAccessibility()
        refreshNotifications()
        checkLocalNetwork()
    }

    // MARK: - Notifications

    private func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: Status = switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .allowed
            case .denied: .off
            case .notDetermined: .notAsked
            @unknown default: .unknown
            }
            Task { @MainActor in Permissions.shared.notifications = status }
        }
    }

    /// Asks once; macOS won't ask again, so after that this opens Settings.
    func turnOnNotifications() {
        guard notifications == .notAsked else {
            openSystemSettings("com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in Permissions.shared.refreshNotifications() }
        }
    }

    /// Asks only if it hasn't been asked: for when a phone first connects,
    /// so the question comes when there's something to show.
    func askForNotificationsIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            Task { @MainActor in Permissions.shared.turnOnNotifications() }
        }
    }

    // MARK: - Accessibility

    private func refreshAccessibility() {
        accessibility = AXIsProcessTrusted() ? .allowed : .off
    }

    /// The first time, macOS's own alert, which adds Tether to the list and
    /// offers System Settings. After that, the list itself.
    func turnOnAccessibility() {
        if !hasAskedForAccessibility {
            hasAskedForAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { return }
        }
        openSystemSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: - Local Network

    /// macOS has no call that returns this (TN3179). A UDP connection to an
    /// address on the local network sends nothing, but its path says when
    /// local network access is denied, and macOS retries it when access is
    /// given. So the probe stays open while access is off, and the status
    /// changes the moment it's turned on.
    private func checkLocalNetwork() {
        guard localNetworkProbe == nil else { return }
        guard let address = LocalNetworkAddress.probe() else {
            localNetwork = .unknown
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: 1716, using: .udp)
        localNetworkProbe = connection
        connection.stateUpdateHandler = { state in
            let status: Status? = switch state {
            case .ready: .allowed
            case .waiting:
                connection.currentPath?.unsatisfiedReason == .localNetworkDenied ? .off : .unknown
            case .failed, .cancelled: .unknown
            default: nil
            }
            guard let status else { return }
            Task { @MainActor in Permissions.shared.updateLocalNetwork(status, from: connection) }
        }
        connection.start(queue: .main)
    }

    private func updateLocalNetwork(_ status: Status, from connection: NWConnection) {
        guard connection === localNetworkProbe else { return }
        localNetwork = status
        // Nothing left to watch for once it's allowed, or once it failed.
        if status != .off {
            connection.cancel()
            localNetworkProbe = nil
        }
    }

    func openLocalNetworkSettings() {
        openSystemSettings("com.apple.preference.security?Privacy_LocalNetwork")
    }

    // MARK: -

    private func openSystemSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// An address on this Mac's local network, to check access against: the
/// first host of the subnet of the first active Wi-Fi or Ethernet interface.
nonisolated enum LocalNetworkAddress {
    static func probe() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_BROADCAST != 0,
                  flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // A point-to-point or /31-/32 link has no other host to name.
            guard mask != 0, ~mask > 1 else { continue }
            var host = (ip & mask) | 1
            if host == ip { host += 1 }
            return [24, 16, 8, 0].map { String((host >> $0) & 0xFF) }.joined(separator: ".")
        }
        return nil
    }
}
