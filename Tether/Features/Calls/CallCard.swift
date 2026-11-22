//
//  CallCard.swift
//  Tether
//
//  Incoming calls in a floating card at the top right instead of a banner,
//  the way an iPhone's calls show up on a Mac. It stays while the phone
//  rings, shrinks to an "on call" pill with a timer once the call is
//  answered, and goes away when the call ends. A missed call is left to the
//  usual notification, so it stays in Notification Center.
//
//  KDE Connect can't answer or decline a call from the computer, only ask
//  the phone to silence its ringer, so the card offers Silence and Dismiss.
//

import AppKit
import SwiftUI

@MainActor
final class CallCard {
    static let shared = CallCard()

    /// Settings › General › "Show calls in a floating card". On by default.
    nonisolated static let settingKey = "tether_call_card"

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    struct Caller {
        /// The contact's name, else the number, else "Unknown number".
        var name: String
        var isContact: Bool
        /// Shown under a contact's name.
        var number: String?
        var photo: NSImage?
        var deviceName: String
    }

    enum Phase {
        case ringing(silenced: Bool)
        case onCall(since: Date)
    }

    private var deviceId: String?
    private var caller: Caller?
    private var phase: Phase?
    /// Dismissed by hand: stays hidden until this call is over.
    private var isDismissed = false
    private var closeTask: Task<Void, Never>?

    private var panel: CallCardPanel?
    private var hosting: NSHostingView<CallCardView>?

    // MARK: - Events from the phone

    func ringing(deviceId: String, caller: Caller) {
        closeTask?.cancel()
        if self.deviceId != deviceId { isDismissed = false }
        self.deviceId = deviceId
        self.caller = caller
        phase = .ringing(silenced: false)
        update()
    }

    /// Answered, or an outgoing call under way.
    func talking(deviceId: String, caller: Caller) {
        closeTask?.cancel()
        if self.deviceId != deviceId { isDismissed = false }
        self.deviceId = deviceId
        self.caller = caller
        if case .onCall = phase {} else { phase = .onCall(since: .now) }
        update()
    }

    /// The phone stopped ringing or hung up.
    func ended(deviceId: String) {
        guard deviceId == self.deviceId else { return }
        // An answered call stops ringing just before "talking" arrives, and a
        // missed one just before "missedCall"; waiting a moment keeps the card
        // from closing and reopening in between.
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.close() }
        }
    }

    func missed(deviceId: String) {
        guard deviceId == self.deviceId else { return }
        close()
    }

    // MARK: - Buttons

    private func silence() {
        guard let deviceId, case .ringing(silenced: false) = phase else { return }
        TelephonyPlugin.muteRinger(deviceId: deviceId)
        phase = .ringing(silenced: true)
        update()
    }

    private func dismiss() {
        isDismissed = true
        hidePanel()
    }

    // MARK: - Panel

    private func close() {
        closeTask?.cancel()
        closeTask = nil
        deviceId = nil
        caller = nil
        phase = nil
        isDismissed = false
        hidePanel()
    }

    private func update() {
        guard let caller, let phase, !isDismissed else {
            TetherLog("[CallCard] Not shown: \(isDismissed ? "dismissed for this call" : "no call")")
            return
        }
        let view = CallCardView(
            caller: caller, phase: phase,
            silence: { [weak self] in self?.silence() },
            dismiss: { [weak self] in self?.dismiss() }
        )
        if let hosting, let panel {
            hosting.rootView = view
            place(panel, size: hosting.fittingSize, animated: true)
        } else {
            showPanel(view)
        }
    }

    private func showPanel(_ view: CallCardView) {
        TetherLog("[CallCard] Showing")
        let hosting = FirstClickHostingView(rootView: view)
        let panel = CallCardPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting

        // Slides in from the right edge, like a notification.
        place(panel, size: hosting.fittingSize, animated: false)
        let target = panel.frame
        if Self.reduceMotion {
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    private func hidePanel() {
        guard let panel else { return }
        TetherLog("[CallCard] Hiding")
        self.panel = nil
        hosting = nil
        if Self.reduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    /// Top right of the screen in use, under the menu bar, where banners appear.
    private func place(_ panel: NSPanel, size: NSSize, animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 14
        let frame = NSRect(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin,
            width: size.width, height: size.height
        )
        panel.setFrame(frame, display: true, animate: animated && !Self.reduceMotion)
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: MotionPreference.key)
    }

    #if DEBUG
    /// Demo data: a ringing card that answers itself after a few seconds.
    func showDemo() {
        let caller = Caller(name: "Maya Fernandes", isContact: true, number: "+1 415 555 0134", photo: nil, deviceName: "Pixel 9 Pro")
        ringing(deviceId: "mock_phone", caller: caller)
        Task {
            try? await Task.sleep(for: .seconds(6))
            talking(deviceId: "mock_phone", caller: caller)
        }
    }
    #endif
}

/// Borderless, so it needs telling that it may take clicks.
private final class CallCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Buttons work on the first click, without focusing the panel first.
private final class FirstClickHostingView: NSHostingView<CallCardView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

struct CallCardView: View {
    let caller: CallCard.Caller
    let phase: CallCard.Phase
    let silence: () -> Void
    let dismiss: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .ringing(let silenced):
                ringing(silenced: silenced)
            case .onCall(let since):
                onCall(since: since)
            }
        }
        // The card never takes focus, and its buttons shouldn't look disabled for it.
        .environment(\.appearsActive, true)
        // Its own window, so it sets the motion preference itself.
        .tetherMotionPreference()
    }

    private func ringing(silenced: Bool) -> some View {
        VStack(spacing: 14) {
            CallerAvatar(caller: caller, size: 76, pulses: !silenced)
                .padding(.top, 4)
            VStack(spacing: 3) {
                Text(caller.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let number = caller.number {
                    Text(number)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Label("Incoming call on \(caller.deviceName)", systemImage: "phone.arrow.down.left.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            HStack(spacing: 36) {
                GlassCircleButton(
                    title: silenced ? "Silenced" : "Silence",
                    systemImage: silenced ? "bell.slash.fill" : "bell.slash",
                    size: 50, action: silence
                )
                .disabled(silenced)
                GlassCircleButton(title: "Dismiss", systemImage: "xmark", size: 50, action: dismiss)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: 280)
        .glassPanel(radius: 32)
        .padding(1)
    }

    private func onCall(since: Date) -> some View {
        HStack(spacing: 10) {
            CallerAvatar(caller: caller, size: 32, pulses: false)
            VStack(alignment: .leading, spacing: 0) {
                Text(caller.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(since, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(width: 230)
        .glassPanel(radius: 100)
        .padding(1)
    }
}

/// The caller's photo, or their initials, with soft rings while it rings.
private struct CallerAvatar: View {
    let caller: CallCard.Caller
    let size: CGFloat
    let pulses: Bool
    @State private var isPulsing = false
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        face
            .frame(width: size, height: size)
            .clipShape(.circle)
            .background {
                if pulses && !reduceMotion {
                    Circle()
                        .stroke(.green.opacity(0.5), lineWidth: 2)
                        .scaleEffect(isPulsing ? 1.35 : 1)
                        .opacity(isPulsing ? 0 : 1)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: isPulsing)
                        .onAppear { isPulsing = true }
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var face: some View {
        if let photo = caller.photo {
            Image(nsImage: photo)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.62), Color(white: 0.45)], startPoint: .top, endPoint: .bottom)
                if let initials {
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .medium, design: .rounded))
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                }
            }
            .foregroundStyle(.white)
        }
    }

    /// Up to two initials from a contact's name.
    private var initials: String? {
        caller.isContact ? InitialsAvatar.initials(of: caller.name) : nil
    }
}
