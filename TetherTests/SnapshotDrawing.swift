//
//  SnapshotDrawing.swift
//  TetherTests
//
//  Drawing a window's view into a PNG at a chosen scale, shared by the UI
//  snapshots and the marketing captures.
//

import AppKit

enum SnapshotDrawing {
    /// Draws `view` at `scale` times its size and writes it as a PNG.
    /// cacheDisplay can't draw Liquid Glass or live materials.
    @MainActor
    static func write(_ view: NSView, scale: CGFloat, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
