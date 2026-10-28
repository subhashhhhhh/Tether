//
//  MenuBarView.swift
//  Tether
//
//  Menu bar popover: floating glass panels, the connected phone first (wearing
//  the same picture as the phone card in the window), then menu-style rows.
//

import SwiftUI
import AppKit

public struct MenuBarView: View {
    @Bindable var appModel: TetherAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false

    public init(appModel: TetherAppModel) {
        self.appModel = appModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .staggeredEntrance(0)

            if let request = appModel.incomingPairRequest {
                pairRequestCard(request)
                    .staggeredEntrance(1)
            }

            if let device = appModel.primaryDevice {
                deviceCard(device)
                    .staggeredEntrance(1)
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

            VStack(spacing: 0) {
                if let release = UpdateController.shared.availableRelease {
                    MenuRow(title: "Update to Tether \(release.version)…", systemImage: "arrow.down.circle") {
                        UpdateController.shared.showWindow()
                    }
                }
                MenuRow(title: "Open Tether", systemImage: "macwindow") { openMainWindow() }
                MenuRow(title: "Settings…", systemImage: "gearshape") {
                    openSettings()
                    NSApp.activate()
                }
                MenuRow(title: "Quit Tether", systemImage: "power") { NSApp.terminate(nil) }
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
        // Just the routine announcement: a full sweep makes a connected phone reconnect.
        .onAppear { appModel.refreshDiscovery(thorough: false) }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Tether")
                .font(.title3.weight(.bold))
            Spacer()
            let connected = !appModel.connectedDevices.isEmpty
            Label(connected ? "Connected" : "Not Connected", systemImage: "circle.fill")
                .labelStyle(StatusDotLabelStyle(color: connected ? .green : .secondary))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

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
                    HStack(spacing: 10) {
                        if let battery = device.batteryPercent {
                            Label("\(battery)%", systemImage: DeviceSymbols.battery(battery, charging: device.isCharging))
                        }
                        if let network = device.networkType, !network.isEmpty {
                            Label(network, systemImage: "cellularbars")
                        }
                        if device.isViaTailscale {
                            Label("Tailscale", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if appModel.connectedDevices.count > 1 { deviceSwitcher }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)

            HStack(spacing: 0) {
                GlassCircleButton(title: "Find", systemImage: "speaker.wave.3.fill", size: 40) { device.findMyPhone() }
                    .frame(maxWidth: .infinity)
                if device.canLock {
                    GlassCircleButton(title: "Lock", systemImage: "lock.fill", size: 40) { device.lockDevice() }
                        .frame(maxWidth: .infinity)
                }
                GlassCircleButton(title: "Clipboard", systemImage: "doc.on.clipboard", size: 40) { device.sendClipboard() }
                    .frame(maxWidth: .infinity)
                GlassCircleButton(title: "Send Files", systemImage: "arrow.up.doc", size: 40) {
                    NSApp.activate()
                    device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name))
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 2)
        }
        .padding(8)
        .glassPanel(radius: 20)
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
        openWindow(id: "main")
        NSApp.activate()
    }
}

// MARK: - Pieces

private struct PopoverCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(radius: 20)
    }
}

/// A label whose icon is a small coloured status dot.
private struct StatusDotLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            configuration.title
        }
    }
}

/// A full-width row that highlights on hover, like an NSMenu item.
private struct MenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(isHovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
