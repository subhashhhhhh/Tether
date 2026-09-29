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

public final class InputSynthesizer: @unchecked Sendable {
    public static let shared = InputSynthesizer()

    private let lock = NSLock()
    private var isLeftButtonPressed = false

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
    public var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant accessibility permission in System Settings.
    public func promptAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings -> Privacy & Security -> Accessibility
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Handles a kdeconnect.mousepad.request packet and synthesizes events.
    @discardableResult
    public func handlePacket(_ packet: NetworkPacket) -> Bool {
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
                // dy = vertical, -dx = horizontal scroll
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: -Int32(dx), wheel3: 0) {
                    event.post(tap: .cghidEventTap)
                }
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

    private func currentMousePosition() -> CGPoint {
        // CGEvent(source: nil)?.location gives global screen coordinates where (0,0) is top-left
        if let event = CGEvent(source: nil) {
            return event.location
        }
        return .zero
    }

    private func setMousePosition(_ point: CGPoint) {
        let isDragging = lock.withLock { self.isLeftButtonPressed }
        if isDragging {
            // When button is held, posting leftMouseDragged is mandatory for OS selection and window dragging
            postMouseEvent(type: .leftMouseDragged, point: point, button: .left)
        } else {
            CGWarpMouseCursorPosition(point)
        }
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
}
