//
//  DockPresence.swift
//  Tether
//
//  Tether in the Dock while a window is open, and the count on its icon.
//

import AppKit

/// Tether lives in the menu bar, but a window with no Dock icon and no
/// menu bar is hard to get back to, and leaves nowhere for Settings. While
/// a window is open the app is a regular one; it goes back to the menu bar
/// alone when the last one closes.
@MainActor
enum DockPresence {
    /// Tests host their views in the app; they shouldn't take the Dock or focus.
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func windowOpened() {
        guard !isTesting else { return }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        // The Dock creates the icon a moment after the switch, and a badge
        // set before then is lost; it's set again once the app is active.
        observeActivation()
        // The Dock takes a second or two to have the icon ready, and ignores
        // the same label set again, so the badge is cleared and set a few
        // times while the icon appears.
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { applyBadge(redraw: true) }
        }
    }

    private static var activationObserver: NSObjectProtocol?

    private static func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { applyBadge(redraw: true) }
        }
    }

    static func windowClosed() {
        guard !isTesting else { return }
        // After the closing window has gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            if !hasWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// The count on the Dock icon, which is there while the window is open.
    private static var badgeCount = 0

    static func setBadge(_ count: Int) {
        guard !isTesting else { return }
        badgeCount = count
        applyBadge()
    }

    private static func applyBadge(redraw: Bool = false) {
        guard NSApp.activationPolicy() == .regular else { return }
        if redraw { NSApp.dockTile.badgeLabel = nil }
        NSApp.dockTile.badgeLabel = badgeCount > 0 ? String(badgeCount) : nil
        NSApp.dockTile.display()
        TetherLog("[Dock] Badge \(badgeCount)")
    }
}
