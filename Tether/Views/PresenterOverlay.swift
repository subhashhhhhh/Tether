//
//  PresenterOverlay.swift
//  Tether
//
//  Full-screen, transparent, click-through overlay showing a red laser pointer dot.
//

import SwiftUI
import AppKit

public final class PresenterOverlayWindowController: @unchecked Sendable {
    @MainActor public static let shared = PresenterOverlayWindowController()

    private var window: NSWindow?
    private var dismissTimer: Timer?
    private var dotPosition = CGPoint(x: 0.5, y: 0.5)
    private var hostingView: NSHostingView<PresenterDotView>?

    private init() {}

    @MainActor
    public func update(xPos: CGFloat, yPos: CGFloat) {
        dotPosition = CGPoint(x: xPos, y: yPos)
        ensureWindow()

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }

        window?.orderFrontRegardless()
    }

    @MainActor
    public func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }

    @MainActor
    private func ensureWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        if window == nil {
            let win = NSWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .screenSaver
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let host = NSHostingView(rootView: PresenterDotView(controller: self))
            win.contentView = host
            self.hostingView = host
            self.window = win
        }

        hostingView?.rootView = PresenterDotView(controller: self)
    }

    public var currentPosition: CGPoint {
        dotPosition
    }
}

public struct PresenterDotView: View {
    let controller: PresenterOverlayWindowController

    public var body: some View {
        GeometryReader { geometry in
            let pos = controller.currentPosition
            let dotSize: CGFloat = max(18, geometry.size.width / 120)
            let x = geometry.size.width * pos.x - (dotSize / 2)
            // macOS screen coords vs SwiftUI: (0,0) top-left in GeometryReader
            let y = geometry.size.height * pos.y - (dotSize / 2)

            Circle()
                .fill(Color.red.opacity(0.85))
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                )
                .frame(width: dotSize, height: dotSize)
                .shadow(color: Color.red.opacity(0.8), radius: 6, x: 0, y: 0)
                .position(x: x + (dotSize / 2), y: y + (dotSize / 2))
        }
        .edgesIgnoringSafeArea(.all)
    }
}
