//
//  MenuBarView.swift
//  Tether
//
//  AirSync-inspired menu bar popover for Tether featuring segmented glass cards,
//  live device status, media playback controls, and quick action buttons.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct MenuBarView: View {
    @Bindable var appModel: TetherAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTarget: Bool = false

    public init(appModel: TetherAppModel = TetherAppModel.shared) {
        self.appModel = appModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            // 1. Top Header Segment
            topHeaderSegment

            // 2. Incoming Pairing Request Segment
            if let pairReq = appModel.incomingPairRequest {
                pairingRequestSegment(for: pairReq)
            }

            // 3. Active Device Segment
            if let connectedDevice = appModel.connectedDevices.first {
                connectedDeviceSegment(for: connectedDevice)

                // 4. Now Playing Media Segment (if music active)
                if let title = connectedDevice.nowPlayingTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    mediaPlayerSegment(for: connectedDevice)
                }
            } else if appModel.allDevices.isEmpty {
                emptyDeviceSegment
            }

            // 5. Available Devices Segment
            if !appModel.availableDevices.isEmpty {
                availableDevicesSegment
            }

            // 6. Footer Segment
            footerSegment
        }
        .padding(14)
        .frame(width: 330)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDroppedFiles(providers)
        }
        .onAppear {
            appModel.refreshDiscovery()
        }
    }

    // MARK: - Top Header Segment
    private var topHeaderSegment: some View {
        GlassCard(cornerRadius: 14, paddingAmount: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image("TetherLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Tether")
                        .font(.system(size: 14, weight: .bold))
                    Text(appModel.connectedDevices.isEmpty ? (appModel.isRunning ? "Searching..." : "Offline") : "Online")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(appModel.connectedDevices.isEmpty ? .secondary : .green)
                }

                Spacer()

                GlassButtonView(
                    label: "Open App",
                    systemImage: "arrow.up.forward.app",
                    circleSize: 30,
                    fixedIconSize: 13,
                    helpText: "Open Tether Main Window"
                ) {
                    openAndFocusMainWindow()
                }
            }
        }
    }

    // MARK: - Pairing Request Segment
    @ViewBuilder
    private func pairingRequestSegment(for request: PairRequestViewModel) -> some View {
        GlassCard(cornerRadius: 14, paddingAmount: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 18))
                        .foregroundColor(.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pairing Request")
                            .font(.system(size: 12, weight: .bold))
                        Text("\(request.deviceName) wants to connect")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let fp = request.fingerprint {
                    Text("Fingerprint: \(fp.prefix(20))...")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Reject", role: .destructive) {
                        appModel.rejectIncomingPairRequest()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button("Accept") {
                        appModel.acceptIncomingPairRequest()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Connected Device Segment
    @ViewBuilder
    private func connectedDeviceSegment(for device: DeviceViewModel) -> some View {
        GlassCard(cornerRadius: 14, paddingAmount: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: device.deviceType.systemImageName)
                        .font(.system(size: 16))
                        .foregroundColor(.accentColor)

                    Text(device.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Spacer()

                    if let batt = device.batteryPercent {
                        HStack(spacing: 3) {
                            Image(systemName: device.isCharging ? "battery.100bolt" : "battery.100")
                                .font(.system(size: 11))
                                .foregroundColor(batt <= 20 ? .red : (device.isCharging ? .accentColor : .primary))
                            Text("\(batt)%")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.green.opacity(0.6), radius: 2)
                }

                // Quick Actions Glass Buttons
                HStack(spacing: 6) {
                    GlassButtonView(
                        label: "Ping",
                        systemImage: "bell.badge",
                        size: .mini,
                        helpText: "Ping Phone"
                    ) {
                        device.ping()
                    }

                    GlassButtonView(
                        label: "Send File",
                        systemImage: "paperclip",
                        size: .mini,
                        helpText: "Send File"
                    ) {
                        openSendFileDialog(for: device)
                    }

                    GlassButtonView(
                        label: "Clipboard",
                        systemImage: "doc.on.clipboard",
                        size: .mini,
                        helpText: "Push Clipboard"
                    ) {
                        device.sendClipboard()
                    }

                    GlassButtonView(
                        label: "Ring",
                        systemImage: "speaker.wave.3.fill",
                        size: .mini,
                        helpText: "Ring Phone"
                    ) {
                        device.findMyPhone()
                    }
                }
            }
        }
    }

    // MARK: - Media Player Segment
    @ViewBuilder
    private func mediaPlayerSegment(for device: DeviceViewModel) -> some View {
        GlassCard(cornerRadius: 14, paddingAmount: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 36, height: 36)
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.nowPlayingTitle ?? "Music")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let artist = device.nowPlayingArtist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        device.previousMedia()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        device.playPauseMedia()
                    } label: {
                        Image(systemName: device.nowPlayingIsPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button {
                        device.nextMedia()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }

    // MARK: - Empty Device Segment
    private var emptyDeviceSegment: some View {
        GlassCard(cornerRadius: 14, paddingAmount: 14) {
            VStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text("No Connected Devices")
                    .font(.system(size: 12, weight: .semibold))
                Text("Ensure KDE Connect is running on your phone.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Available Devices Segment
    private var availableDevicesSegment: some View {
        GlassCard(cornerRadius: 14, paddingAmount: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NEARBY DEVICES")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)

                ForEach(appModel.availableDevices) { dev in
                    HStack(spacing: 8) {
                        Image(systemName: dev.deviceType.systemImageName)
                            .foregroundColor(.blue)
                        Text(dev.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Button("Pair") {
                            dev.pair()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }

    // MARK: - Footer Segment
    private var footerSegment: some View {
        HStack {
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text("Settings...")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                    Text("Quit")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func openAndFocusMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSendFileDialog(for device: DeviceViewModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        if panel.runModal() == .OK {
            for url in panel.urls {
                device.sendFile(url: url)
            }
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard let targetDevice = appModel.connectedDevices.first else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        targetDevice.sendFile(url: url)
                    }
                } else if let url = item as? URL {
                    DispatchQueue.main.async {
                        targetDevice.sendFile(url: url)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Previews

#Preview("Menu Bar - Connected") {
    MenuBarView(appModel: .mock())
        .preferredColorScheme(.dark)
}

#Preview("Menu Bar - Empty") {
    MenuBarView(appModel: .mockEmpty())
}
