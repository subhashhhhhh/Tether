//
//  KDEConnectApp.swift
//  KDEConnect
//

import SwiftUI

@main
struct KDEConnectApp: App {
    @StateObject private var service = KDEConnectService.shared

    init() {
        // Start background discovery and network services
        KDEConnectService.shared.start()
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
    }
}
