//
//  MenuBarView.swift
//  Tether
//
//  Menu bar popover: what's new on the phone without opening the window.
//  The phone and its state, its latest notifications and anything else
//  waiting, what it's playing, then actions and app rows as menu items. One
//  surface, as system menus are, with dividers between sections.
//

import SwiftUI
import AppKit

public struct MenuBarView: View {
    @Bindable var appModel: TetherAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false
    /// What Send Clipboard would send, read when the popover opens.
    @State private var clipboardPreview: String?

    public init(appModel: TetherAppModel) {
        self.appModel = appModel
    }

    public var body: some View {
        // Spacing groups the sections. The one divider sets the app's own rows
        // apart, as a menu does, and sits as close to its neighbours as a
        // menu's separator: the rows either side have padding of their own.
        VStack(alignment: .leading, spacing: 4) {
          VStack(alignment: .leading, spacing: 12) {
            if let request = appModel.incomingPairRequest {
                pairRequestCard(request)
                    .staggeredEntrance(0)
            }

            if let device = appModel.primaryDevice {
                deviceCard(device)
                    .staggeredEntrance(1)
                actions(device)
                    .staggeredEntrance(1)
                activity(device)
                    .staggeredEntrance(2)
                if device.hasNowPlaying {
                    nowPlayingCard(device)
                        .staggeredEntrance(2)
                }
            } else {
                emptyCard
                    .staggeredEntrance(1)
            }

            if !appModel.availableDevices.isEmpty {
                nearbyCard
                    .staggeredEntrance(3)
            }
          }

            Divider()

            VStack(spacing: 0) {
                if let release = UpdateController.shared.availableRelease {
                    MenuRow(title: "Update to Tether \(release.version)…", systemImage: "arrow.down.circle") {
                        closePopover()
                        UpdateController.shared.showWindow()
                    }
                }
                MenuRow(title: "Open Tether", systemImage: "macwindow") { openMainWindow() }
                MenuRow(title: "Settings…", systemImage: "gearshape", shortcut: ",") {
                    closePopover()
                    openSettings()
                    NSApp.activate()
                }
                MenuRow(title: "Quit Tether", systemImage: "power", shortcut: "q") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
        .dropDestination(for: URL.self) { urls, _ in
            guard let device = appModel.primaryDevice else { return false }
            let files = urls.filter(\.isFileURL)
            device.sendFiles(files)
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted, let device = appModel.primaryDevice {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .overlay {
                        Label("Send to \(device.name)", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: .capsule)
                    }
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // Just the routine announcement: a thorough one makes a connected phone reconnect.
        .onAppear {
            appModel.refreshDiscovery(thorough: false)
            clipboardPreview = NSPasteboard.general.string(forType: .string).map(Self.preview)
        }
    }

    // MARK: - Sections

    private func deviceCard(_ device: DeviceViewModel) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: device.deviceType.systemImageName)
                    .font(.system(size: 26, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    // The phone's state reads on the phone, not in a title above it.
                    HStack(spacing: 10) {
                        // How it's connected says that it is: green, as on the overview.
                        if !device.isViaTailscale {
                            Label {
                                Text("Wi-Fi")
                            } icon: {
                                Image(systemName: "wifi").foregroundStyle(.green)
                            }
                        }
                        if let battery = device.batteryPercent {
                            Label("\(battery)%", systemImage: DeviceSymbols.battery(battery, charging: device.isCharging))
                        }
                        if let network = device.networkType, !network.isEmpty {
                            Label(network, systemImage: "cellularbars")
                        }
                        if device.isViaTailscale {
                            Label {
                                Text("Tailscale")
                            } icon: {
                                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.green)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                }
                Spacer(minLength: 0)
                if appModel.connectedDevices.count > 1 { deviceSwitcher }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
        .padding(.top, 2)
    }

    // MARK: What's waiting

    /// Notifications, unread texts and a running transfer: the things you'd
    /// open the window to check.
    @ViewBuilder
    private func activity(_ device: DeviceViewModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(title: "Notifications", systemImage: "bell",
                    detail: device.notifications.isEmpty ? "None" : "\(device.notifications.count)") {
                open(.notifications, on: device)
            }
            ForEach(device.notifications.prefix(3)) { item in
                PopoverNotificationRow(item: item) { open(.notifications, on: device) }
            }

            let unread = device.smsThreads.reduce(0) { $0 + $1.unreadCount }
            if unread > 0 {
                MenuRow(title: "Messages", systemImage: "message", detail: "\(unread) unread") {
                    open(.messages, on: device)
                }
            }

            // Says what it will send, so there's no guessing which way it goes.
            MenuRow(title: "Send Clipboard", systemImage: "doc.on.clipboard",
                    subtitle: clipboardPreview.flatMap { $0.isEmpty ? nil : $0 } ?? "Nothing copied on this Mac") {
                closePopover()
                device.sendClipboard()
            }
            .help("Send this Mac's clipboard to \(device.name)")
            .disabled(clipboardPreview?.isEmpty ?? true)

            if let transfer = device.transfers.first(where: { $0.status == .transferring }) {
                Button { open(.files, on: device) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label {
                            Text(transfer.filename)
                        } icon: {
                            Image(systemName: transfer.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                                .frame(width: 20)
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        ProgressView(value: transfer.progress)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(transfer.filename), \(Int(transfer.progress * 100)) percent")
            }
        }
    }

    // MARK: Actions

    /// What you do to the phone: one row of small tiles, each with its name.
    private func actions(_ device: DeviceViewModel) -> some View {
        HStack(spacing: 8) {
            ActionTile(title: "Ring Phone", systemImage: "speaker.wave.3") {
                closePopover()
                device.findMyPhone()
            }
            .help("Ring \(device.name) at full volume")
            if device.canLock {
                ActionTile(title: "Lock", systemImage: "lock") {
                    closePopover()
                    device.lockDevice()
                }
            }
            ActionTile(title: "Send Files", systemImage: "arrow.up.doc") {
                closePopover()
                NSApp.activate()
                device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name))
            }
            .help("Choose files to send to \(device.name)")
        }
        .padding(.horizontal, 6)
    }

    /// One line of the clipboard. The row truncates it to fit.
    private static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(120))
    }

    private func open(_ section: DeviceSection, on device: DeviceViewModel) {
        appModel.sectionRequest = SectionRequest(deviceId: device.id, section: section)
        openMainWindow()
    }

    private var deviceSwitcher: some View {
        Menu {
            Picker("Device", selection: $appModel.selectedDeviceId) {
                ForEach(appModel.connectedDevices) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.callout.weight(.semibold))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Choose device")
    }

    private func nowPlayingCard(_ device: DeviceViewModel) -> some View {
        PopoverCard {
            HStack(spacing: 10) {
                Group {
                    if let image = device.albumArt {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.quaternary)
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.nowPlayingTitle ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(device.nowPlayingArtist ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                HStack(spacing: 12) {
                    Button(device.nowPlayingIsPlaying ? "Pause" : "Play",
                           systemImage: device.nowPlayingIsPlaying ? "pause.fill" : "play.fill") {
                        device.playPauseMedia()
                    }
                    .contentTransition(.symbolEffect(.replace))
                    Button("Next", systemImage: "forward.fill") { device.nextMedia() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
            }
        }
    }

    private func pairRequestCard(_ request: PairRequestViewModel) -> some View {
        PopoverCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    DeviceSymbol(type: request.deviceType)
                        .font(.title2)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pairing Request")
                            .font(.subheadline.weight(.semibold))
                        Text("\(request.deviceName) wants to pair")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        appModel.rejectIncomingPairRequest()
                    } label: {
                        Text("Decline").frame(maxWidth: .infinity)
                    }
                    Button {
                        appModel.acceptIncomingPairRequest(request)
                    } label: {
                        Text("Pair").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var emptyCard: some View {
        PopoverCard {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appModel.offlineDevices.isEmpty ? "No Devices" : "Not Connected")
                        .font(.subheadline.weight(.medium))
                    Text(appModel.offlineDevices.isEmpty
                         ? "Open KDE Connect on your phone to pair."
                         : "Looking for \(appModel.offlineDevices.map(\.name).formatted(.list(type: .or)))…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var nearbyCard: some View {
        PopoverCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nearby")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(appModel.availableDevices) { device in
                    HStack(spacing: 10) {
                        DeviceSymbol(type: device.deviceType, isActive: false)
                            .frame(width: 20)
                        Text(device.name)
                            .lineLimit(1)
                        Spacer()
                        if device.isAwaitingPairing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Pair") { device.pair() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func openMainWindow() {
        closePopover()
        openWindow(id: "main")
        NSApp.activate()
    }

    /// A menu closes when you choose from it. The popover is the key window
    /// at the moment of the click, so it's closed directly if the dismiss
    /// action leaves it up.
    private func closePopover() {
        let popover = NSApp.keyWindow
        dismiss()
        DispatchQueue.main.async {
            if popover?.isVisible == true { popover?.close() }
        }
    }
}

// MARK: - Pieces

/// A section of the popover. The popover is already a panel, so a section is
/// only padding; dividers set the sections apart.
private struct PopoverCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small action button for a row of them: the symbol over its name.
private struct ActionTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(height: 18)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .foregroundStyle(.primary)
        }
        .glassButton()
        .buttonBorderShape(.roundedRectangle(radius: 10))
    }
}

/// One notification in the popover: who it's from and what it says, on two
/// lines. A sign-in code can be copied without leaving the popover.
private struct PopoverNotificationRow: View {
    let item: PhoneNotification
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title.isEmpty ? item.appName : item.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(item.title.isEmpty ? "" : item.appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if let code = item.code {
                CopyCodeButton(code: code, isCompact: true)
                    .controlSize(.small)
                    .fixedSize()
            } else {
                Text(item.date, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        // Indented to the row titles above, past their icons.
        .padding(.leading, 36)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }
}

/// A full-width row that highlights on hover, like an NSMenu item, with a
/// detail or its key equivalent at the trailing edge.
private struct MenuRow: View {
    let title: String
    let systemImage: String
    /// A count or state shown at the trailing edge ("3", "2 unread").
    var detail: String?
    /// A second line under the title, cut short if it's long.
    var subtitle: String?
    /// The key pressed with Command, if the row has an equivalent.
    var shortcut: Character?
    let action: () -> Void
    @State private var isHovering = false

    private var trailing: String? {
        detail ?? shortcut.map { "⌘\(String($0).uppercased())" }
    }

    var body: some View {
        Button(action: action) {
            HStack {
                // One icon column, so titles line up whatever the symbol's width.
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(isHovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                                .truncationMode(.tail)
                        }
                    }
                } icon: {
                    Image(systemName: systemImage)
                        .frame(width: 20)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .monospacedDigit()
                        .foregroundStyle(isHovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isHovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .modifier(OptionalShortcut(key: shortcut))
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: Character?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}

#if DEBUG
#Preview("Connected") {
    MenuBarView(appModel: .mock())
}

#Preview("Pair request") {
    MenuBarView(appModel: .mockPairRequest())
}

#Preview("Empty") {
    MenuBarView(appModel: .mockEmpty())
}
#endif
