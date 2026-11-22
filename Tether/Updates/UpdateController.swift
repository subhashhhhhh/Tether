//
//  UpdateController.swift
//  Tether
//
//  Checks GitHub for a newer Tether once a day, announces it with a
//  notification, and installs it from the Software Update window.
//
//  Homebrew stays out of the way: the cask declares `auto_updates true`, so
//  `brew upgrade` leaves a self-updating Tether alone.
//

import AppKit
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableRelease)
        case installing(AvailableRelease, UpdateInstaller.Phase)
        case failed(String)
    }

    static let notificationCategory = "TETHER_UPDATE"
    private static let automaticKey = "tether_update_automatic"
    private static let lastCheckedKey = "tether_update_last_checked"
    private static let skippedKey = "tether_update_skipped_version"
    private static let checkInterval: TimeInterval = 24 * 3600

    private(set) var state: State = .idle
    /// A newer release found by any check, shown in the menu bar until installed.
    private(set) var availableRelease: AvailableRelease?
    private(set) var lastChecked: Date?

    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Self.automaticKey) }
    }

    /// Only a release build signed with Tether's certificate can check a download
    /// against itself; a local build offers the download page instead.
    let canInstall: Bool = BundleSignature.canVerifyUpdates

    var currentVersion: String { AppVersion.current?.description ?? "–" }

    private var schedule: Task<Void, Never>?
    private var installation: Task<Void, Never>?
    private var window: NSWindow?
    private var announcedVersion: AppVersion?

    private init() {
        let defaults = UserDefaults.standard
        checksAutomatically = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    // MARK: - Checking

    func start() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            // Stay out of the login rush.
            try? await Task.sleep(for: .seconds(30), tolerance: .seconds(10))
            while !Task.isCancelled {
                guard let self else { return }
                if self.checksAutomatically, self.isCheckDue {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(3600), tolerance: .seconds(300))
            }
        }
    }

    private var isCheckDue: Bool {
        guard let lastChecked else { return true }
        return Date().timeIntervalSince(lastChecked) >= Self.checkInterval
    }

    /// From the menu or Settings: always opens the window with the answer.
    func checkForUpdates() {
        showWindow()
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        if case .installing = state { return }
        if userInitiated { state = .checking }

        let release: AvailableRelease?
        do {
            release = try await ReleaseFeed.latest()
        } catch {
            TetherLog("[Updater] Check failed: \(error.localizedDescription)")
            if userInitiated { state = .failed("Couldn't check for updates. \(error.localizedDescription)") }
            return
        }

        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)

        guard let release, let current = AppVersion.current, release.version > current else {
            availableRelease = nil
            if userInitiated { state = .upToDate }
            return
        }

        TetherLog("[Updater] Tether \(release.version) is available (running \(current))")
        availableRelease = release
        if userInitiated {
            state = .available(release)
        } else {
            if case .available = state {} else if case .failed = state {} else { state = .available(release) }
            announce(release)
        }
    }

    /// One notification per version, and none for a version the user skipped.
    private func announce(_ release: AvailableRelease) {
        guard announcedVersion != release.version,
              UserDefaults.standard.string(forKey: Self.skippedKey) != release.version.description else { return }
        announcedVersion = release.version

        let content = UNMutableNotificationContent()
        content.title = "Tether \(release.version) is available"
        content.body = "Click to see what's new and install it."
        content.categoryIdentifier = Self.notificationCategory
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "tether-update-\(release.version)", content: content, trigger: nil)
        )
    }

    // MARK: - Actions

    func install() {
        guard case .available(let release) = state, installation == nil else { return }
        let installer = UpdateInstaller.standard
        state = .installing(release, .downloading(received: 0, expected: release.archiveSize))

        installation = Task { [weak self] in
            do {
                try await installer.install(release) { phase in
                    Task { @MainActor in
                        guard let self, case .installing = self.state else { return }
                        self.state = .installing(release, phase)
                    }
                }
                Relauncher.relaunchAfterExit(installer.bundleURL)
                NSApp.terminate(nil)
            } catch is CancellationError {
                self?.state = .available(release)
            } catch {
                TetherLog("[Updater] Install failed: \(error.localizedDescription)")
                self?.state = .failed(error.localizedDescription)
            }
            self?.installation = nil
        }
    }

    func cancelInstall() {
        installation?.cancel()
    }

    /// Stops the notification for this version; Check for Updates still offers it.
    func skip() {
        if case .available(let release) = state {
            UserDefaults.standard.set(release.version.description, forKey: Self.skippedKey)
        }
        closeWindow()
    }

    func openReleasePage() {
        let url: URL
        switch state {
        case .available(let release), .installing(let release, _): url = release.pageURL
        default: url = availableRelease?.pageURL ?? ReleaseFeed.releasesPage
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Window

    /// Opens Software Update, with the available release if one is known.
    func showWindow() {
        if case .installing = state {} else if let availableRelease, state == .idle || state == .upToDate {
            state = .available(availableRelease)
        }

        if window == nil {
            let hosting = NSHostingController(rootView: UpdateWindowView(controller: self).tetherMotionPreference())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Software Update"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// For screenshots: puts the window in a given state without a network check.
    func setPreviewState(_ state: State) {
        self.state = state
    }
    #endif

    func closeWindow() {
        window?.close()
        if case .installing = state { return }
        state = .idle
    }
}
