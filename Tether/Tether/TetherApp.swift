//
//  TetherApp.swift
//  Tether
//

import SwiftUI

@main
struct TetherApp: App {
    @StateObject private var service = TetherService.shared

    init() {
        // Eagerly initialize identity on main thread
        _ = DeviceIdentity.shared
        // Start background discovery and network services
        TetherService.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            let iconName: String = {
                let hasPairedAndConnected = service.connectedDevices.values.contains { !$0.isDisconnected && $0.pairState == .paired }
                if hasPairedAndConnected {
                    return "iphone.badge.checkmark"
                } else if service.isRunning {
                    return "antenna.radiowaves.left.and.right"
                } else {
                    return "antenna.radiowaves.left.and.right.slash"
                }
            }()
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        WindowGroup(id: "main") {
            MainWindowView()
        }
        .defaultSize(width: 820, height: 560)
    }
}
