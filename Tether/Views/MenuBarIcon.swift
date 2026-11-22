//
//  MenuBarIcon.swift
//  Tether
//
//  The menu bar icon: a phone. Empty when nothing is waiting; with the
//  count on its screen when notifications or unread texts are. A template image, so
//  macOS tints it for light, dark and highlighted menu bars.
//

import AppKit

enum MenuBarIcon {
    static let size = NSSize(width: 13, height: 19)

    /// - Parameters:
    ///   - count: Notifications and unread texts waiting; above 9 shows "*".
    ///   - isConnected: No phone connected draws the outline faintly.
    static func image(count: Int, isConnected: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(count: count, isConnected: isConnected)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = count > 0
            ? "\(count) waiting on your phone"
            : (isConnected ? "Phone connected" : "No phone connected")
        return image
    }

    private static func draw(count: Int, isConnected: Bool) {
        let ink = NSColor.black.withAlphaComponent(isConnected ? 1 : 0.45)
        let body = NSRect(x: 1, y: 0.5, width: size.width - 2, height: size.height - 1)

        // A phone, not a pill: tight corners, and thicker bezels at the top
        // and bottom than at the sides. Drawn as the body with its glass cut
        // out, so the bezels can differ.
        let side: CGFloat = 1.1, end: CGFloat = 1.9
        let glass = NSRect(x: body.minX + side, y: body.minY + end,
                           width: body.width - side * 2, height: body.height - end * 2)
        let frame = NSBezierPath(roundedRect: body, xRadius: 1.75, yRadius: 1.75)
        frame.append(NSBezierPath(roundedRect: glass, xRadius: 0.8, yRadius: 0.8))
        frame.windingRule = .evenOdd
        ink.setFill()
        frame.fill()

        guard count > 0 else { return }

        // The count, drawn inside the glass and centred on its own outline.
        let text = count > 9 ? "*" : "\(count)"
        guard let outline = outline(of: text, in: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)) else { return }
        // Filled as a shape: the outline that's centred is exactly the one
        // drawn, with no text layout or hinting in between.
        let bounds = outline.boundingBoxOfPath
        var move = CGAffineTransform(translationX: glass.midX - bounds.midX, y: glass.midY - bounds.midY)
        guard let placed = outline.copy(using: &move), let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(placed)
        context.setFillColor(ink.cgColor)
        context.fillPath()
    }

    /// The glyphs of `text`, laid out on one line, as a single path.
    private static func outline(of text: String, in font: NSFont) -> CGPath? {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let shape = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                path.addPath(shape, transform: CGAffineTransform(translationX: position.x, y: position.y))
            }
        }
        return path.isEmpty ? nil : path
    }
}
