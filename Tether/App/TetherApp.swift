//
//  TetherApp.swift
//  Tether
//

import SwiftUI

@main
struct TetherApp: App {
    @State private var appModel: TetherAppModel

    init() {
        // AppKit adds Enter Full Screen to a View menu on its own, which
        // would keep a View menu Tether doesn't otherwise have. The window's
        // green button and Window › Full Screen Tile still do it.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        #if DEBUG
        // `-TetherDemoData` fills the UI with sample devices for screenshots and
        // design work, without touching the network.
        // `-TetherDemoRinging` also shows the Ring panel, without sound.
        // `-TetherDemoCall` also shows the incoming-call card.
        if ProcessInfo.processInfo.arguments.contains("-TetherDemoData") {
            _appModel = State(initialValue: .mock())
            PhoneFilesController.shared.showDemoDrive(for: "mock_phone")
            if ProcessInfo.processInfo.arguments.contains("-TetherDemoRinging") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MacRinger.shared.showDemoPanel(deviceName: "Pixel 9 Pro")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-TetherDemoCall") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    CallCard.shared.showDemo()
                }
            }
            return
        }
        #endif

        _appModel = State(initialValue: .shared)

        // Unit tests run inside a copy of the app. Starting the services there
        // would connect to the phone next to the real Tether and unmount its
        // phone drive as a "leftover".
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        QuitOnTerminateSignal.install()
        // Eagerly initialize identity on main thread
        _ = DeviceIdentity.shared
        // Start background discovery and network services
        TetherService.shared.start()
        // Receive what's shared from the Share menu
        ShareInbox.shared.start()
        // Look for a newer release once a day
        UpdateController.shared.start()
        // Serve the phone's storage to Finder
        PhoneFilesController.shared.start()
    }

    /// Demo data opens the main window at `-TetherDemoSection <section>`
    /// (overview when not given).
    private static var demoSection: DeviceSection? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-TetherDemoData") else { return nil }
        return UserDefaults.standard.string(forKey: "TetherDemoSection").flatMap(DeviceSection.init) ?? .overview
        #else
        return nil
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appModel: appModel)
                .tetherMotionPreference()
        } label: {
            Image(nsImage: MenuBarIcon.image(count: appModel.waitingCount,
                                             isConnected: !appModel.connectedDevices.isEmpty))
        }
        .menuBarExtraStyle(.window)

        Window("Tether", id: "main") {
            MainWindowView(appModel: appModel, initialSection: Self.demoSection ?? .overview)
                .tetherMotionPreference()
        }
        .defaultSize(width: 1040, height: 700)
        .defaultLaunchBehavior(Self.demoSection == nil ? .automatic : .presented)
        .windowToolbarStyle(.unified)
        .commands {
            TetherCommands(appModel: appModel)
        }

        Settings {
            SettingsView(viewModel: .shared)
                .tetherMotionPreference()
        }
    }
}
