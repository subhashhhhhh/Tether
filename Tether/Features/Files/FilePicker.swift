//
//  FilePicker.swift
//  Tether
//
//  Choosing files to send, and the icons files are shown with.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    /// Finder's icon for the file's type, looked up once per extension.
    static func image(for filename: String) -> NSImage {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = icon
        return icon
    }
}

enum FilePicker {
    /// Shows an open panel for choosing files to send. Returns an empty array on cancel.
    @MainActor
    static func chooseFiles(sendingTo deviceName: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(deviceName)"
        return panel.runModal() == .OK ? panel.urls : []
    }
}
