//
//  MenuBarView.swift
//  Tether
//

import SwiftUI
import UniformTypeIdentifiers

public struct MenuBarView: View {
    @ObservedObject var service = TetherService.shared
    @ObservedObject var trustStore = TrustStore.shared
    @ObservedObject var batteryPlugin: BatteryPlugin
    @ObservedObject var mediaPlugin: MediaControlPlugin
    @ObservedObject var connectivityPlugin: ConnectivityReportPlugin
    @ObservedObject var remoteVolumePlugin: RemoteVolumePlugin
    @ObservedObject var sharePlugin: SharePlugin
    @State private var isDropTarget = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    public init() {
        self.batteryPlugin = TetherService.shared.batteryPlugin
        self.mediaPlugin = TetherService.shared.mediaControlPlugin
        self.connectivityPlugin = TetherService.shared.connectivityReportPlugin
        self.remoteVolumePlugin = TetherService.shared.remoteVolumePlugin
        self.sharePlugin = TetherService.shared.sharePlugin
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(service.isRunning ? .green : .secondary)
                Text(DeviceIdentity.shared.deviceName)
                    .font(.headline)
                Spacer()
                Text(service.isRunning ? "Online" : "Offline")
                    .font(.caption)
                    .foregroundColor(service.isRunning ? .green : .secondary)
            }
            .padding(.horizontal, 4)

            Divider()

            // Incoming Pairing Request Banner
            if let pairReq = service.incomingPairRequest {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .foregroundColor(.accentColor)
                        Text("Pairing Request")
                            .font(.subheadline)
                            .bold()
                    }
                    Text("\(pairReq.info.deviceName) wants to pair.")
                        .font(.caption)

                    if let fp = pairReq.connection.peerCertificateFingerprint {
                        Text("Fingerprint:\n\(fp)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Button("Reject", role: .destructive) {
                            service.rejectIncomingPairRequest()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Button("Accept") {
                            service.acceptIncomingPairRequest()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)

                Divider()
            }

            // Paired Devices Section
            VStack(alignment: .leading, spacing: 6) {
                Text("PAIRED DEVICES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                if trustStore.pairedDevices.isEmpty {
                    Text("No paired devices yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(trustStore.pairedDevices.values)) { paired in
                        deviceRow(for: paired)
                    }
                }
            }

            // Discovered (Unpaired) Devices Section
            let unpairedDiscovered = service.discoveredDevices.filter {
                !trustStore.isTrusted(deviceId: $0.deviceId)
            }

            if !unpairedDiscovered.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("AVAILABLE TO PAIR")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)

                    ForEach(unpairedDiscovered) { discovered in
                        HStack {
                            Image(systemName: discovered.deviceType.systemImageName)
                                .foregroundColor(.primary)
                            Text(discovered.deviceName)
                                .font(.caption)
                            Spacer()
                            Button("Pair") {
                                service.requestPair(with: discovered)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Transfers Section
            if !sharePlugin.transfers.isEmpty {
                Divider()
                transfersSection
            }

            Divider()

            // Footer
            HStack {
                Button("Open Tether") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                Button("Settings...") {
                    openSettings()
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 290)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor, lineWidth: isDropTarget ? 2 : 0)
                .background(isDropTarget ? Color.accentColor.opacity(0.1) : Color.clear)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDroppedFiles(providers)
        }
        .onAppear {
            service.refreshDiscovery()
            // Pull fresh media/volume state each time the popover opens.
            for deviceId in service.connectedDevices.keys {
                service.refreshRemoteState(deviceId: deviceId)
            }
        }
    }

    @ViewBuilder
    private func deviceRow(for device: PairedDevice) -> some View {
        let isConnected = (service.connectedDevices[device.deviceId]?.isDisconnected == false)
        let battery = batteryPlugin.deviceBatteries[device.deviceId]
        let signal = connectivityPlugin.signalStrength[device.deviceId]
        let nowPlaying = mediaPlugin.nowPlaying[device.deviceId]
        let sink = remoteVolumePlugin.sinks[device.deviceId]?.first(where: { $0.enabled })

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: device.deviceType.systemImageName)
                    .foregroundColor(isConnected ? .primary : .secondary)

                Text(device.deviceName)
                    .font(.body)
                    .foregroundColor(isConnected ? .primary : .secondary)

                Spacer()

                if let signal {
                    signalBadge(for: signal)
                }

                if let batt = battery {
                    HStack(spacing: 3) {
                        Text("\(batt.currentCharge)%")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: batt.isCharging ? "battery.100.bolt" : "battery.100")
                            .foregroundColor(batt.currentCharge < 20 ? .red : .green)
                    }
                }

                Circle()
                    .fill(isConnected ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
            }

            if isConnected {
                HStack(spacing: 6) {
                    Button(action: {
                        service.sendPing(to: device.deviceId)
                    }) {
                        Label("Ping", systemImage: "bell.badge")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button(action: {
                        sendFilesDialog(for: device.deviceId)
                    }) {
                        Label("Send File", systemImage: "paperplane")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Spacer()

                    Menu {
                        Button("Send File...") {
                            sendFilesDialog(for: device.deviceId)
                        }
                        Button("Send Clipboard to Phone") {
                            if let string = NSPasteboard.general.string(forType: .string), !string.isEmpty {
                                service.sendText(string, to: device.deviceId)
                            }
                        }
                        Divider()
                        Button("Ring Phone") {
                            service.ringPhone(device.deviceId)
                        }
                        Button("Lock Phone") {
                            service.lockPhone(device.deviceId)
                        }
                        Divider()
                        Toggle("Clipboard Sync", isOn: Binding(
                            get: { device.isClipboardSyncEnabled },
                            set: { newValue in
                                trustStore.updateSettings(
                                    deviceId: device.deviceId,
                                    clipboard: newValue,
                                    notifications: device.isNotificationSyncEnabled
                                )
                            }
                        ))
                        Toggle("Notification Sync", isOn: Binding(
                            get: { device.isNotificationSyncEnabled },
                            set: { newValue in
                                trustStore.updateSettings(
                                    deviceId: device.deviceId,
                                    clipboard: device.isClipboardSyncEnabled,
                                    notifications: newValue
                                )
                            }
                        ))
                        Divider()
                        Button("Unpair", role: .destructive) {
                            service.unpair(deviceId: device.deviceId)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
                .padding(.leading, 24)

                if let sink {
                    volumeRow(for: device, sink: sink)
                }

                if let nowPlaying, nowPlaying.hasTrack {
                    nowPlayingRow(for: device, state: nowPlaying)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func volumeRow(for device: PairedDevice, sink: AudioSink) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sink.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Slider(
                value: Binding(
                    get: { sink.fraction },
                    set: { service.setPhoneVolume(Int($0 * Double(sink.maxVolume)), deviceId: device.deviceId) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
        }
        .padding(.leading, 24)
    }

    @ViewBuilder
    private func nowPlayingRow(for device: PairedDevice, state: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(state.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if !state.elapsedLabel.isEmpty {
                    Text(state.elapsedLabel)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            if !state.artist.isEmpty {
                Text(state.artist)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 10) {
                Button(action: { service.mediaAction("Previous", deviceId: device.deviceId) }) {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!state.canGoPrevious)

                Button(action: {
                    service.mediaAction(state.isPlaying ? "Pause" : "Play", deviceId: device.deviceId)
                }) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)

                Button(action: { service.mediaAction("Next", deviceId: device.deviceId) }) {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!state.canGoNext)

                Spacer()
            }
            .font(.system(size: 11))
        }
        .padding(.leading, 24)
        .padding(.top, 2)
    }

    /// Network type plus a four-bar strength indicator. Strength is reported on a
    /// 0...4 scale, where 0 still means "connected, no bars".
    @ViewBuilder
    private func signalBadge(for signal: SignalStrength) -> some View {
        HStack(spacing: 3) {
            Text(signal.shortLabel)
                .font(.system(size: 10, weight: .medium))

            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(index < signal.strength ? Color.secondary : Color.secondary.opacity(0.25))
                        .frame(width: 2, height: CGFloat(4 + index * 2))
                }
            }
            .frame(height: 10, alignment: .bottom)
        }
    }

    @ViewBuilder
    private var transfersSection: some View {
        let recent = Array(sharePlugin.transfers.prefix(3))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("TRANSFERS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if let count = sharePlugin.transfers.count as Int?, count > 3 {
                    Text("\(count) total")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            ForEach(recent) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: item.direction == .outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundColor(item.status == .completed ? .green : (item.status == .transferring ? .accentColor : .secondary))
                            .font(.system(size: 11))

                        Text(item.filename)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        switch item.status {
                        case .transferring:
                            Text(item.formattedProgress)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        case .completed:
                            Text("Done")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        case .failed:
                            Text("Failed")
                                .font(.system(size: 9))
                                .foregroundColor(.red)
                        case .cancelled:
                            Text("Cancelled")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        case .queued:
                            Text("Queued")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }

                    if item.status == .transferring {
                        ProgressView(value: item.progress)
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func sendFilesDialog(for deviceId: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        panel.message = "Choose files to send to phone"
        panel.begin { response in
            if response == .OK && !panel.urls.isEmpty {
                service.sendFiles(panel.urls, to: deviceId)
            }
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard let firstConnected = service.connectedDevices.first(where: { !$0.value.isDisconnected && $0.value.pairState == .paired }) else {
            return false
        }
        let deviceId = firstConnected.key

        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    defer { group.leave() }
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    } else if let url = item as? URL {
                        urls.append(url)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                service.sendFiles(urls, to: deviceId)
            }
        }
        return true
    }
}

