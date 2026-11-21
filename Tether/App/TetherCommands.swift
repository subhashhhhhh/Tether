//
//  TetherCommands.swift
//  Tether
//
//  The menu bar's commands: the Tether menu's extras and the Device menu.
//

import SwiftUI
import AppKit

struct TetherCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let appModel: TetherAppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tether") { TetherCredits.showAboutPanel() }
            Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
        }

        // In the Tether menu, not a File menu: Tether has no documents.
        CommandGroup(after: .appSettings) {
            Button("Connect by Address…") {
                openWindow(id: "main")
                appModel.isShowingConnectByIP = true
            }
            .keyboardShortcut("k")

            Button("Look for Devices") { appModel.refreshDiscovery() }
                .keyboardShortcut("r")
        }

        // No File or View menu. Emptying their groups removes them.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .sidebar) {}
        CommandGroup(replacing: .toolbar) {}

        CommandMenu("Device") {
            // Named, so it's clear which phone a command reaches when the
            // selected one is offline and another is used instead.
            let device = appModel.primaryDevice
            command(.sendFiles, on: device, key: "o")
            command(.sendClipboard, on: device, key: "c", modifiers: [.command, .shift])
            Divider()
            command(.findPhone, on: device, key: "f", modifiers: [.command, .shift])
            if device?.canLock == true {
                command(.lock, on: device, key: "l", modifiers: [.command, .shift])
            }
            command(.ping, on: device)
        }
    }

    private func command(_ action: DeviceAction, on device: DeviceViewModel?,
                         key: KeyEquivalent? = nil, modifiers: EventModifiers = .command) -> some View {
        let button = Button(device.map(action.menuTitle(for:)) ?? action.title) {
            if let device { action.perform(on: device) }
        }
        .disabled(device == nil)
        return Group {
            if let key { button.keyboardShortcut(key, modifiers: modifiers) } else { button }
        }
    }
}
