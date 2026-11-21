//
//  UISnapshots.swift
//  TetherTests
//
//  Renders the main screens to PNG for design review. Skipped unless the
//  TETHER_SNAPSHOT_DIR environment variable is set, e.g.
//
//    TEST_RUNNER_TETHER_SNAPSHOT_DIR=/tmp/shots xcodebuild test ... -only-testing:TetherTests/UISnapshots
//

import Testing
import SwiftUI
import AppKit
import ScreenCaptureKit
@testable import Tether

@MainActor
@Suite struct UISnapshots {
    static let outputDirectory = ProcessInfo.processInfo.environment["TETHER_SNAPSHOT_DIR"]

    @Test(.enabled(if: outputDirectory != nil))
    func renderScreens() async throws {
        let dir = URL(fileURLWithPath: Self.outputDirectory!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let windowSize = CGSize(width: 1100, height: 720)
        PhoneFilesController.shared.showDemoDrive(for: "mock_phone")

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for section in DeviceSection.allCases {
                try await render(MainWindowView(appModel: .mock(), initialSection: section),
                                 size: windowSize, dark: dark, to: dir.appendingPathComponent("main-\(section.rawValue)-\(suffix).png"))
            }
            if let phone = TetherAppModel.mock().connectedDevices.first(where: { $0.id == "mock_phone" }) {
                try await render(MessagesPane(device: phone, startsComposing: true), size: CGSize(width: 820, height: 560),
                                 dark: dark, to: dir.appendingPathComponent("messages-compose-\(suffix).png"))
            }
            try await render(MenuBarView(appModel: .mock()), size: CGSize(width: 320, height: 480), dark: dark,
                             titled: false, to: dir.appendingPathComponent("menubar-\(suffix).png"))
        }

        UserDefaults.standard.set("mock_phone", forKey: "tether_folded_devices")
        let folded = TetherAppModel.mock()
        folded.selectedDeviceId = "mock_tablet"
        try await render(MainWindowView(appModel: folded, initialSection: .notifications), size: windowSize, dark: true,
                         to: dir.appendingPathComponent("main-folded-dark.png"))
        UserDefaults.standard.removeObject(forKey: "tether_folded_devices")

        try await render(MainWindowView(appModel: .mockEmpty()), size: windowSize, dark: false,
                         to: dir.appendingPathComponent("main-onboarding-light.png"))

        let nearby = TetherAppModel.mock()
        nearby.selectedDeviceId = "mock_available"
        try await render(MainWindowView(appModel: nearby), size: windowSize, dark: false,
                         to: dir.appendingPathComponent("main-nearby-light.png"))

        let offline = TetherAppModel.mock()
        offline.selectedDeviceId = "mock_offline"
        try await render(MainWindowView(appModel: offline), size: windowSize, dark: true,
                         to: dir.appendingPathComponent("main-offline-dark.png"))

        let request = TetherAppModel.mockPairRequest().incomingPairRequest!
        try await render(PairRequestSheet(request: request, onAccept: {}, onDecline: {}), size: CGSize(width: 420, height: 440),
                         dark: false, titled: false, to: dir.appendingPathComponent("pair-request-light.png"))
        try await render(ConnectByIPSheet { _ in true }, size: CGSize(width: 400, height: 200),
                         dark: false, titled: false, to: dir.appendingPathComponent("connect-ip-light.png"))
        try await render(MenuBarView(appModel: .mockPairRequest()), size: CGSize(width: 320, height: 560), dark: false,
                         titled: false, to: dir.appendingPathComponent("menubar-pair-light.png"))
        try await render(SettingsView(viewModel: .mock()), size: CGSize(width: 560, height: 500), dark: false,
                         to: dir.appendingPathComponent("settings-light.png"))
        let release = AvailableRelease(
            version: AppVersion("1.6")!, tag: "v1.6",
            notes: ReleaseFeed.changelog(from: try String(contentsOfFile: #filePath.replacingOccurrences(
                of: "TetherTests/UISnapshots.swift", with: "dist/notes-1.5.md"), encoding: .utf8)),
            pageURL: ReleaseFeed.releasesPage, archiveURL: ReleaseFeed.releasesPage,
            archiveSize: 2_900_000, archiveSHA256: nil)
        let updateStates: [(String, UpdateController.State)] = [
            ("available", .available(release)),
            ("installing", .installing(release, .downloading(received: 1_200_000, expected: 2_900_000))),
            ("uptodate", .upToDate),
            ("failed", .failed("Couldn't check for updates. The Internet connection appears to be offline.")),
        ]
        for (name, state) in updateStates {
            UpdateController.shared.setPreviewState(state)
            try await render(UpdateWindowView(controller: .shared), size: CGSize(width: 480, height: name == "available" || name == "installing" ? 400 : 160),
                             dark: name == "installing", to: dir.appendingPathComponent("update-\(name).png"))
        }

        try await render(FilesSettings(viewModel: .mock()), size: CGSize(width: 560, height: 460), dark: false,
                         to: dir.appendingPathComponent("files-settings-light.png"))

        for dark in [false, true] {
            try await render(RingingView(deviceName: "Pixel 9 Pro") {}, size: CGSize(width: 340, height: 230), dark: dark,
                             titled: false, to: dir.appendingPathComponent("ringing-\(dark ? "dark" : "light").png"))
        }

        for dark in [false, true] {
            try await render(AboutSettings(), size: CGSize(width: 560, height: 460), dark: dark,
                             to: dir.appendingPathComponent("about-\(dark ? "dark" : "light").png"))
        }
    }

    /// Hosts `view` in a real window and snapshots the window frame, so toolbars
    /// and other window chrome are included.
    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, titled: Bool = true, to url: URL) async throws {
        let style: NSWindow.StyleMask = titled
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless]
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        window.setContentSize(size)
        // Active, as people see the window they're using: accent-coloured
        // selection and a toolbar that isn't dimmed.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(900))

        // TETHER_SNAPSHOT_SCALE=2 draws at that scale, for crisp marketing
        // images on a 1x display, at the cost of Liquid Glass.
        if let scale = ProcessInfo.processInfo.environment["TETHER_SNAPSHOT_SCALE"].flatMap(Double.init), scale > 1,
           let frameView = window.contentView?.superview ?? window.contentView {
            frameView.layoutSubtreeIfNeeded()
            let bounds = frameView.bounds
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = bounds.size
            frameView.cacheDisplay(in: bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            return
        }

        // Capture through the window server, so Liquid Glass and materials
        // appear as they do on screen; cacheDisplay can't draw them.
        if let image = try? await Self.captureWindow(window) {
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            return
        }
        guard let frameView = window.contentView?.superview ?? window.contentView else { return }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func captureWindow(_ window: NSWindow) async throws -> CGImage? {
        let content = try await SCShareableContent.currentProcess
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
