//
//  TetherApp.swift
//  Tether
//

import SwiftUI

@main
struct TetherApp: App {
    @State private var appModel = TetherAppModel.shared

    init() {
        // Eagerly initialize identity on main thread
        _ = DeviceIdentity.shared
        // Start background discovery and network services
        TetherService.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("Tether", image: appModel.statusMenuBarImageName) {
            MenuBarView(appModel: appModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        WindowGroup(id: "main") {
            MainWindowView(appModel: appModel)
        }
        .defaultSize(width: 860, height: 580)
    }
}
