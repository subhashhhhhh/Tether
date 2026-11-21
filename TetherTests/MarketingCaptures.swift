//
//  MarketingCaptures.swift
//  TetherTests
//
//  Renders the real app screens with sample data at 2x, for the README and
//  launch graphics. Skipped unless TETHER_MARKETING_DIR is set:
//
//    TEST_RUNNER_TETHER_MARKETING_DIR=/path xcodebuild test ... \
//      -only-testing:TetherTests/MarketingCaptures
//

import Testing
import SwiftUI
import AppKit
@testable import Tether

@MainActor
@Suite struct MarketingCaptures {
    static let outputDirectory = ProcessInfo.processInfo.environment["TETHER_MARKETING_DIR"]

    @Test(.enabled(if: outputDirectory != nil))
    func captureScreens() async throws {
        let dir = URL(fileURLWithPath: Self.outputDirectory!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            try await capture(MainWindowView(appModel: .mock(), initialSection: .overview),
                              size: CGSize(width: 1120, height: 720), dark: dark, to: dir.appendingPathComponent("window-overview-\(theme).png"))
            try await capture(MainWindowView(appModel: .mock(), initialSection: .messages),
                              size: CGSize(width: 1120, height: 720), dark: dark, to: dir.appendingPathComponent("window-messages-\(theme).png"))
            try await capture(MainWindowView(appModel: .mock(), initialSection: .notifications),
                              size: CGSize(width: 1120, height: 720), dark: dark, to: dir.appendingPathComponent("window-notifications-\(theme).png"))
            try await capture(MenuBarView(appModel: .mock()).fixedSize(),
                              size: nil, dark: dark, titled: false, to: dir.appendingPathComponent("menubar-\(theme).png"))
            // 4x: the graphics enlarge this one.
            try await capture(SettingsView(viewModel: .mock()),
                              size: CGSize(width: 560, height: 560), dark: dark, scale: 4, to: dir.appendingPathComponent("settings-\(theme).png"))
        }
    }

    /// Hosts the view in an on-screen, key window (so selection and prominent
    /// buttons draw in their active colours) and caches the window at 2x.
    private func capture<V: View>(_ view: V, size: CGSize?, dark: Bool, titled: Bool = true, scale: CGFloat = 2, to url: URL) async throws {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let hosting = NSHostingController(rootView: AnyView(
            size.map { AnyView(view.frame(width: $0.width, height: $0.height)) } ?? AnyView(view)
        ))
        let style: NSWindow.StyleMask = titled
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = style
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.title = "Tether"
        if let size { window.setContentSize(size) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(1500))

        // cacheDisplay can't composite live vibrancy (it draws selected sidebar
        // rows black and dims sidebar text), so draw materials as their solid
        // fallback for the capture.
        if let root = window.contentView?.superview { Self.flattenMaterials(in: root) }
        try await Task.sleep(for: .milliseconds(300))

        guard let frameView = window.contentView?.superview ?? window.contentView else { return }
        try SnapshotDrawing.write(frameView, scale: scale, to: url)
    }

    private static func flattenMaterials(in view: NSView) {
        if let effect = view as? NSVisualEffectView {
            effect.state = .inactive
        }
        for subview in view.subviews { flattenMaterials(in: subview) }
    }
}
