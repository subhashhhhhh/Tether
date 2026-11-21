//
//  InputSynthesizer.swift
//  Tether
//
//  Synthesizes mouse and keyboard events using CoreGraphics.
//  Direct port of upstream macOS remote input (macosremoteinput.mm).
//

import Foundation
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox
import AppKit

nonisolated final class InputSynthesizer: @unchecked Sendable {
    static let shared = InputSynthesizer()

    private let lock = NSLock()
    private var isLeftButtonPressed = false
    /// Where Tether last put the pointer, and when. Reading the position
    /// back straight after moving it can lag, which skewed movement; it's
    /// read from the system again only after a pause, when the real mouse
    /// may have moved it.
    private var pointer: CGPoint?
    private var pointerMovedAt = Date.distantPast
    /// When the last scroll arrived. Lifting two fingers after a scroll
    /// sends a tap, which mustn't click.
    private var lastScrollAt = Date.distantPast
    private let scroller = MomentumScroller()

    /// Upstream SpecialKeysMap table verbatim (macosremoteinput.mm:16-50)
    private static let specialKeysMap: [CGKeyCode] = [
        0,                                      // 0: Invalid
        CGKeyCode(kVK_Delete),                  // 1
        CGKeyCode(kVK_Tab),                     // 2
        CGKeyCode(kVK_Return),                  // 3
        CGKeyCode(kVK_LeftArrow),               // 4
        CGKeyCode(kVK_UpArrow),                 // 5
        CGKeyCode(kVK_RightArrow),              // 6
        CGKeyCode(kVK_DownArrow),               // 7
        CGKeyCode(kVK_PageUp),                  // 8
        CGKeyCode(kVK_PageDown),                // 9
        CGKeyCode(kVK_Home),                    // 10
        CGKeyCode(kVK_End),                     // 11
        CGKeyCode(kVK_Return),                  // 12
        CGKeyCode(kVK_ForwardDelete),           // 13
        CGKeyCode(kVK_Escape),                  // 14
        0,                                      // 15
        0,                                      // 16
        CGKeyCode(kVK_Control),                 // 17
        CGKeyCode(kVK_Option),                  // 18
        CGKeyCode(kVK_Shift),                   // 19
        CGKeyCode(kVK_Command),                 // 20
        CGKeyCode(kVK_F1),                      // 21
        CGKeyCode(kVK_F2),                      // 22
        CGKeyCode(kVK_F3),                      // 23
        CGKeyCode(kVK_F4),                      // 24
        CGKeyCode(kVK_F5),                      // 25
        CGKeyCode(kVK_F6),                      // 26
        CGKeyCode(kVK_F7),                      // 27
        CGKeyCode(kVK_F8),                      // 28
        CGKeyCode(kVK_F9),                      // 29
        CGKeyCode(kVK_F10),                     // 30
        CGKeyCode(kVK_F11),                     // 31
        CGKeyCode(kVK_F12),                     // 32
    ]

    private init() {}

    /// Checks if accessibility permission is granted to synthesize events.
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Opens System Settings -> Privacy & Security -> Accessibility
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Handles a kdeconnect.mousepad.request packet and synthesizes events.
    @discardableResult
    func handlePacket(_ packet: NetworkPacket) -> Bool {
        guard isAccessibilityTrusted else {
            TetherLog("[InputSynthesizer] Dropped event: Accessibility permission not granted")
            return false
        }

        let dx = packet.double(for: "dx")
        let dy = packet.double(for: "dy")
        let x = packet.has("x") ? packet.double(for: "x") : nil
        let y = packet.has("y") ? packet.double(for: "y") : nil

        let isSingleClick = packet.bool(for: "singleclick")
        let isDoubleClick = packet.bool(for: "doubleclick")
        let isMiddleClick = packet.bool(for: "middleclick")
        let isRightClick = packet.bool(for: "rightclick")
        let isSingleHold = packet.bool(for: "singlehold")
        let isSingleRelease = packet.bool(for: "singlerelease")
        let isScroll = packet.bool(for: "scroll")
        let key = packet.string(for: "key") ?? ""
        let specialKey = packet.int(for: "specialKey")
        let validSpecialKey = (specialKey > 0 && specialKey < Self.specialKeysMap.count)

        if isSingleClick || isDoubleClick || isMiddleClick || isRightClick ||
            isSingleHold || isSingleRelease || isScroll || !key.isEmpty || validSpecialKey {

            let currentPoint = currentMousePosition()
            let isClick = isSingleClick || isDoubleClick || isMiddleClick || isRightClick
            if isClick || isSingleHold {
                scroller.stop()
                if Date().timeIntervalSince(lock.withLock { lastScrollAt }) < Self.tapAfterScrollWindow {
                    return true
                }
            }

            if isSingleClick {
                postMouseEvent(type: .leftMouseDown, point: currentPoint, button: .left)
                postMouseEvent(type: .leftMouseUp, point: currentPoint, button: .left)
                lock.withLock { self.isLeftButtonPressed = false }
            } else if isDoubleClick {
                // First click
                postMouseEvent(type: .leftMouseDown, point: currentPoint, button: .left)
                postMouseEvent(type: .leftMouseUp, point: currentPoint, button: .left)

                // Second click with click state = 2
                if let eventDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentPoint, mouseButton: .left) {
                    eventDown.setIntegerValueField(.mouseEventClickState, value: 2)
                    eventDown.post(tap: .cghidEventTap)
                }
                if let eventUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentPoint, mouseButton: .left) {
                    eventUp.setIntegerValueField(.mouseEventClickState, value: 2)
                    eventUp.post(tap: .cghidEventTap)
                }
                lock.withLock { self.isLeftButtonPressed = false }
            } else if isMiddleClick {
                postMouseEvent(type: .otherMouseDown, point: currentPoint, button: .center)
                postMouseEvent(type: .otherMouseUp, point: currentPoint, button: .center)
            } else if isRightClick {
                postMouseEvent(type: .rightMouseDown, point: currentPoint, button: .right)
                postMouseEvent(type: .rightMouseUp, point: currentPoint, button: .right)
            } else if isSingleHold {
                postMouseEvent(type: .leftMouseDown, point: currentPoint, button: .left)
                lock.withLock { self.isLeftButtonPressed = true }
            } else if isSingleRelease {
                postMouseEvent(type: .leftMouseUp, point: currentPoint, button: .left)
                lock.withLock { self.isLeftButtonPressed = false }
            } else if isScroll {
                // dy = vertical, -dx = horizontal scroll, sent as a trackpad
                // scroll so it ends with an inertial glide.
                lock.withLock { lastScrollAt = Date() }
                scroller.scroll(vertical: dy, horizontal: -dx)
            } else if !key.isEmpty || validSpecialKey {
                let ctrl = packet.bool(for: "ctrl") ?? false
                let alt = packet.bool(for: "alt") ?? false
                let shift = packet.bool(for: "shift") ?? false
                let superKey = packet.bool(for: "super") ?? false

                // Press modifiers
                if ctrl { postKeyEvent(keyCode: CGKeyCode(kVK_Control), isDown: true) }
                if alt { postKeyEvent(keyCode: CGKeyCode(kVK_Option), isDown: true) }
                if shift { postKeyEvent(keyCode: CGKeyCode(kVK_Shift), isDown: true) }
                if superKey { postKeyEvent(keyCode: CGKeyCode(kVK_Command), isDown: true) }

                if validSpecialKey {
                    let code = Self.specialKeysMap[specialKey]
                    postKeyEvent(keyCode: code, isDown: true)
                    postKeyEvent(keyCode: code, isDown: false)
                } else {
                    for char in key.utf16 {
                        var unichar = char
                        if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unichar)
                            event.post(tap: .cgSessionEventTap)
                        }
                    }
                }

                // Release modifiers in reverse order
                if superKey { postKeyEvent(keyCode: CGKeyCode(kVK_Command), isDown: false) }
                if shift { postKeyEvent(keyCode: CGKeyCode(kVK_Shift), isDown: false) }
                if alt { postKeyEvent(keyCode: CGKeyCode(kVK_Option), isDown: false) }
                if ctrl { postKeyEvent(keyCode: CGKeyCode(kVK_Control), isDown: false) }
            }
        } else {
            // Mouse move / drag event
            if dx != 0 || dy != 0 {
                let current = currentMousePosition()
                let target = CGPoint(x: current.x + CGFloat(dx), y: current.y + CGFloat(dy))
                setMousePosition(target)
            } else if let x = x, let y = y {
                setMousePosition(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
        }

        return true
    }

    // MARK: - Event Helpers

    /// A tap this soon after a scroll is the second finger lifting.
    private static let tapAfterScrollWindow: TimeInterval = 0.3

    private func currentMousePosition() -> CGPoint {
        let tracked = lock.withLock { () -> CGPoint? in
            Date().timeIntervalSince(pointerMovedAt) < 0.5 ? pointer : nil
        }
        if let tracked { return tracked }
        // Global coordinates, (0,0) at the top left of the main display.
        return CGEvent(source: nil)?.location ?? .zero
    }

    /// Moves the pointer as a mouse would: a moved (or dragged) event with
    /// its deltas, not a jump. macOS then updates the cursor's shape at a
    /// window's edge, shows a hidden Dock, and apps see the movement.
    private func setMousePosition(_ point: CGPoint) {
        let from = currentMousePosition()
        let to = Self.clampedToDisplays(point)
        let isDragging = lock.withLock { () -> Bool in
            pointer = to
            pointerMovedAt = Date()
            return isLeftButtonPressed
        }
        let type: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: to, mouseButton: .left) else { return }
        event.setDoubleValueField(.mouseEventDeltaX, value: to.x - from.x)
        event.setDoubleValueField(.mouseEventDeltaY, value: to.y - from.y)
        event.post(tap: .cghidEventTap)
    }

    /// Keeps the pointer on a screen, as a real mouse stays.
    private static func clampedToDisplays(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let bounds = displays.map(CGDisplayBounds)
        if bounds.contains(where: { $0.contains(point) }) { return point }
        // Off every screen: onto the nearest point of the nearest one.
        let nearest = bounds.map { rect in
            CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1), y: min(max(point.y, rect.minY), rect.maxY - 1))
        }.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }
        return nearest ?? point
    }

    private func postMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton) {
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func postKeyEvent(keyCode: CGKeyCode, isDown: Bool) {
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) {
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Media keys

    enum MediaKey: Int32 {
        case playPause = 16 // NX_KEYTYPE_PLAY
        case next = 17      // NX_KEYTYPE_NEXT
        case previous = 18  // NX_KEYTYPE_PREVIOUS
    }

    /// Presses a media key, as the keyboard's ⏯ ⏭ ⏮ do. Unlike MediaRemote
    /// commands, every player obeys these, Safari included. Returns false
    /// without Accessibility access.
    @discardableResult
    func pressMediaKey(_ key: MediaKey) -> Bool {
        guard isAccessibilityTrusted else { return false }
        for down in [true, false] {
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: Int((key.rawValue << 16) | ((down ? 0xa : 0xb) << 8)), data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// A scroll amount from the peer as a wheel delta. Int32(_:) traps on a
    /// value out of range or not a number.
    nonisolated static func wheelDelta(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(max(-10_000, min(10_000, value.rounded())))
    }
}

/// Scrolls as a trackpad does: a gesture that begins, changes and ends,
/// then a glide that slows to a stop, so apps scroll with inertia. The
/// phone sends only deltas while fingers move.
private nonisolated final class MomentumScroller: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.subhashh.tether.scroll", qos: .userInteractive)
    private var isScrolling = false
    private var velocity = CGVector.zero
    private var lastDeltaAt = Date.distantPast
    private var endTimer: DispatchSourceTimer?
    private var glideTimer: DispatchSourceTimer?

    /// No delta for this long means the fingers lifted.
    private static let liftGap: TimeInterval = 0.08
    private static let frame: TimeInterval = 1.0 / 60
    private static let friction: CGFloat = 0.94

    func scroll(vertical: Double, horizontal: Double) {
        queue.async {
            self.stopGlide()
            let now = Date()
            let interval = max(now.timeIntervalSince(self.lastDeltaAt), Self.frame)
            self.lastDeltaAt = now
            let delta = CGVector(dx: horizontal, dy: vertical)
            // Per-frame speed, smoothed over the last few deltas.
            let perFrame = CGVector(dx: delta.dx * Self.frame / interval, dy: delta.dy * Self.frame / interval)
            self.velocity = self.isScrolling
                ? CGVector(dx: self.velocity.dx * 0.5 + perFrame.dx * 0.5, dy: self.velocity.dy * 0.5 + perFrame.dy * 0.5)
                : perFrame
            Self.post(delta, phase: self.isScrolling ? .changed : .began)
            self.isScrolling = true
            self.scheduleEnd()
        }
    }

    /// A click or press ends any glide, as touching a trackpad does.
    func stop() {
        queue.async {
            self.stopGlide()
            self.endTimer?.cancel()
            self.endTimer = nil
            if self.isScrolling {
                Self.post(.zero, phase: .ended)
                self.isScrolling = false
            }
        }
    }

    private func scheduleEnd() {
        endTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.liftGap)
        timer.setEventHandler { [weak self] in self?.fingersLifted() }
        timer.resume()
        endTimer = timer
    }

    private func fingersLifted() {
        endTimer = nil
        guard isScrolling else { return }
        isScrolling = false
        Self.post(.zero, phase: .ended)
        guard hypot(velocity.dx, velocity.dy) > 1 else { return }
        Self.post(velocity, momentum: .begin)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.frame, repeating: Self.frame, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.glide() }
        timer.resume()
        glideTimer = timer
    }

    private func glide() {
        velocity = CGVector(dx: velocity.dx * Self.friction, dy: velocity.dy * Self.friction)
        if hypot(velocity.dx, velocity.dy) < 0.5 {
            stopGlide()
        } else {
            Self.post(velocity, momentum: .continuous)
        }
    }

    private func stopGlide() {
        guard let glideTimer else { return }
        glideTimer.cancel()
        self.glideTimer = nil
        Self.post(.zero, momentum: .end)
    }

    private enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }
    private enum Momentum: Int64 { case begin = 1, continuous = 2, end = 3 }

    private static func post(_ delta: CGVector, phase: Phase? = nil, momentum: Momentum? = nil) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: InputSynthesizer.wheelDelta(delta.dy),
                                  wheel2: InputSynthesizer.wheelDelta(delta.dx), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta.dy)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta.dx)
        if let phase { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue) }
        if let momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue) }
        event.post(tap: .cghidEventTap)
    }
}
