//
//  PresenterPlugin.swift
//  Tether
//
//  Presentation remote laser pointer plugin.
//

import Foundation
import AppKit

public final class PresenterPlugin: TetherPlugin, @unchecked Sendable {
    public static let presenterType = "kdeconnect.presenter"

    public var supportedPacketTypes: [String] {
        [Self.presenterType]
    }

    private let lock = NSLock()
    private var xPos: CGFloat = 0.5
    private var yPos: CGFloat = 0.5

    public init() {}

    public func onConnected(connection: DeviceConnection) {}
    public func onDisconnected(connection: DeviceConnection) {
        Task { @MainActor in
            PresenterOverlayWindowController.shared.hide()
        }
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == Self.presenterType else { return }

        if packet.bool(for: "stop") == true {
            lock.withLock {
                self.xPos = 0.5
                self.yPos = 0.5
            }
            Task { @MainActor in
                PresenterOverlayWindowController.shared.hide()
            }
            return
        }

        let dx = CGFloat(packet.double(for: "dx"))
        let dy = CGFloat(packet.double(for: "dy"))

        let (newX, newY) = lock.withLock { () -> (CGFloat, CGFloat) in
            let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
            let ratio = screenSize.width / max(screenSize.height, 1)

            self.xPos = min(max(self.xPos + dx, 0.0), 1.0)
            self.yPos = min(max(self.yPos + (dy * ratio), 0.0), 1.0)
            return (self.xPos, self.yPos)
        }

        Task { @MainActor in
            PresenterOverlayWindowController.shared.update(xPos: newX, yPos: newY)
        }
    }
}
