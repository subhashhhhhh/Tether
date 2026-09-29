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
                if !service.connectedDevices.isEmpty {
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
