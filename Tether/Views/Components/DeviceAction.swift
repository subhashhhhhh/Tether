//
//  DeviceAction.swift
//  Tether
//
//  What you can do to a connected device, defined once so the popover,
//  the Home page, the sidebar's menu and the Device menu name and draw
//  each the same way.
//

import AppKit

enum DeviceAction: CaseIterable {
    case findPhone, lock, sendFiles, sendClipboard, ping

    /// The short name, for a button or tile.
    var title: String {
        switch self {
        case .findPhone: "Find Phone"
        case .lock: "Lock"
        case .sendFiles: "Send Files"
        case .sendClipboard: "Send Clipboard"
        case .ping: "Ping"
        }
    }

    /// The name in a menu, which says which device it reaches, and ends in
    /// "…" when it asks for more first.
    func menuTitle(for device: DeviceViewModel) -> String {
        switch self {
        case .findPhone: "Ring \(device.name)"
        case .lock: "Lock \(device.name)"
        case .sendFiles: "Send Files to \(device.name)…"
        case .sendClipboard: "Send Clipboard to \(device.name)"
        case .ping: "Ping \(device.name)"
        }
    }

    var systemImage: String {
        switch self {
        case .findPhone: "speaker.wave.3"
        case .lock: "lock"
        case .sendFiles: "arrow.up.doc"
        case .sendClipboard: "doc.on.clipboard"
        case .ping: "bell"
        }
    }

    func help(for device: DeviceViewModel) -> String {
        switch self {
        case .findPhone: "Ring \(device.name) at full volume"
        case .lock: "Lock \(device.name)"
        case .sendFiles: "Choose files to send to \(device.name)"
        case .sendClipboard: "Send this Mac's clipboard to \(device.name)"
        case .ping: "Send a ping to \(device.name)"
        }
    }

    func isAvailable(on device: DeviceViewModel) -> Bool {
        switch self {
        case .lock: device.canLock
        default: device.isConnected
        }
    }

    func perform(on device: DeviceViewModel) {
        switch self {
        case .findPhone: device.findMyPhone()
        case .lock: device.lockDevice()
        case .sendFiles:
            // The file panel needs Tether in front, from the popover too.
            NSApp.activate()
            device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name))
        case .sendClipboard: device.sendClipboard()
        case .ping: device.ping()
        }
    }
}
