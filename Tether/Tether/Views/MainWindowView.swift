//
//  MainWindowView.swift
//  Tether
//
//  Main application window with NavigationSplitView for Devices, Media, Transfers, Messages, and Commands.
//

import SwiftUI
import UniformTypeIdentifiers

public enum NavigationSection: String, CaseIterable, Identifiable {
    case devices = "Devices"
    case media = "Now Playing"
    case transfers = "Transfers"
    case messages = "Messages"
    case commands = "Commands"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .devices: return "iphone.gen3"
        case .media: return "play.tv"
        case .transfers: return "arrow.up.arrow.down.circle"
        case .messages: return "bubble.left.and.bubble.right"
        case .commands: return "terminal"
        }
    }
}

public struct MainWindowView: View {
    @ObservedObject var service = TetherService.shared
    @State private var selectedSection: NavigationSection? = .devices

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $selectedSection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.icon)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .listStyle(.sidebar)
        } detail: {
            switch selectedSection ?? .devices {
            case .devices:
                DevicesDetailView()
            case .media:
                MediaDetailView()
            case .transfers:
                TransfersDetailView()
            case .messages:
                MessagesView()
            case .commands:
                CommandsView()
            }
        }
        .frame(minWidth: 750, minHeight: 480)
    }
}

// MARK: - Transfers Detail View

struct TransfersDetailView: View {
    @ObservedObject var sharePlugin = TetherService.shared.sharePlugin
    @ObservedObject var service = TetherService.shared
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            if sharePlugin.transfers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No Transfers")
                        .font(.title3.weight(.medium))
                    Text("Drop files here or click Send File to transfer to your phone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Send File...") {
                        openSendFileDialog()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(sharePlugin.transfers) { item in
                        TransferRow(item: item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Transfers")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: openSendFileDialog) {
                    Label("Send File", systemImage: "paperplane")
                }
                .help("Send files to connected device")

                Button(action: {
                    sharePlugin.clearCompleted()
                }) {
                    Label("Clear Finished", systemImage: "trash")
                }
                .disabled(!sharePlugin.transfers.contains(where: { $0.status == .completed || $0.status == .cancelled }))
                .help("Clear completed and cancelled transfers")
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: isDropTarget ? 3 : 0)
                .background(isDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDroppedFiles(providers)
        }
    }

    private func openSendFileDialog() {
        guard let first = service.connectedDevices.first(where: { !$0.value.isDisconnected && $0.value.pairState == .paired }) else {
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(first.value.peerDeviceInfo?.deviceName ?? "device")"
        panel.begin { response in
            if response == .OK && !panel.urls.isEmpty {
                service.sendFiles(panel.urls, to: first.key)
            }
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard let first = service.connectedDevices.first(where: { !$0.value.isDisconnected && $0.value.pairState == .paired }) else {
            return false
        }
        let deviceId = first.key

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

struct TransferRow: View {
    let item: TransferItem
    @ObservedObject var sharePlugin = TetherService.shared.sharePlugin

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text(statusLabel)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)
                }

                HStack {
                    Text("\(item.direction == .outgoing ? "To" : "From") \(item.deviceName)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text(item.formattedSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if item.status == .transferring {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(item.formattedProgress)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }

                if item.status == .transferring {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                }
            }

            // Action buttons
            HStack(spacing: 6) {
                if item.status == .completed, let url = item.localURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if item.status == .transferring {
                    Button("Cancel") {
                        sharePlugin.cancelTransfer(id: item.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return .green
        case .transferring: return .accentColor
        case .failed: return .red
        case .cancelled: return .secondary
        case .queued: return .orange
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .completed: return "Completed"
        case .transferring: return "Transferring"
        case .failed(let msg): return "Failed: \(msg)"
        case .cancelled: return "Cancelled"
        case .queued: return "Queued"
        }
    }
}

// MARK: - Devices Detail View

struct DevicesDetailView: View {
    @ObservedObject var service = TetherService.shared
    @ObservedObject var batteryPlugin = TetherService.shared.batteryPlugin
    @ObservedObject var connectivityPlugin = TetherService.shared.connectivityReportPlugin

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Incoming pair request banner if present
                if let pairReq = service.incomingPairRequest {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pairing Request from \(pairReq.info.deviceName)")
                                .font(.headline)
                            if let fp = pairReq.connection.peerCertificateFingerprint {
                                Text("Key: \(fp.prefix(23))...")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Button("Reject") {
                            service.rejectIncomingPairRequest()
                        }
                        .buttonStyle(.bordered)

                        Button("Accept") {
                            service.acceptIncomingPairRequest()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(10)
                }

                // Paired & Connected Devices
                let paired = Array(service.trustStore.pairedDevices.values)
                VStack(alignment: .leading, spacing: 12) {
                    Text("PAIRED DEVICES")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)

                    if paired.isEmpty {
                        Text("No paired devices. Make sure KDE Connect is running on your phone and on the same Wi-Fi.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(paired) { device in
                            let conn = service.connectedDevices[device.deviceId]
                            let isConnected = conn != nil && !conn!.isDisconnected
                            DeviceCard(device: device, isConnected: isConnected)
                        }
                    }
                }

                // Discovered Unpaired Devices
                let unpaired = service.discoveredDevices.filter { !service.trustStore.isTrusted(deviceId: $0.deviceId) }
                if !unpaired.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AVAILABLE TO PAIR")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)

                        ForEach(unpaired) { info in
                            HStack {
                                Image(systemName: "iphone")
                                    .font(.system(size: 20))
                                    .foregroundColor(.secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.deviceName)
                                        .font(.headline)
                                    Text(info.deviceId)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button("Pair") {
                                    service.requestPair(with: info)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding()
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    service.refreshDiscovery()
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

struct DeviceCard: View {
    let device: PairedDevice
    let isConnected: Bool
    @ObservedObject var service = TetherService.shared
    @ObservedObject var batteryPlugin = TetherService.shared.batteryPlugin
    @ObservedObject var connectivityPlugin = TetherService.shared.connectivityReportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: isConnected ? "iphone.badge.checkmark" : "iphone.slash")
                    .font(.system(size: 28))
                    .foregroundColor(isConnected ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(device.deviceName)
                            .font(.headline)

                        Circle()
                            .fill(isConnected ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 8, height: 8)

                        Text(isConnected ? "Connected" : "Offline")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        if let battery = batteryPlugin.deviceBatteries[device.deviceId] {
                            HStack(spacing: 4) {
                                Image(systemName: battery.isCharging ? "battery.100.bolt" : "battery.100")
                                    .foregroundColor(battery.isCharging ? .green : .secondary)
                                Text("\(battery.currentCharge)%")
                                    .font(.caption)
                            }
                        }

                        if let signal = connectivityPlugin.signalStrength[device.deviceId] {
                            HStack(spacing: 4) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundColor(.secondary)
                                Text(signal.shortLabel)
                                    .font(.caption)
                            }
                        }
                    }
                }

                Spacer()

                if isConnected {
                    HStack(spacing: 8) {
                        Button(action: {
                            service.sendPing(to: device.deviceId)
                        }) {
                            Label("Ping", systemImage: "bell.badge")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(action: {
                            service.ringPhone(device.deviceId)
                        }) {
                            Label("Ring", systemImage: "speaker.wave.3")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(action: {
                            service.lockPhone(device.deviceId)
                        }) {
                            Label("Lock", systemImage: "lock")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Menu {
                    Button(role: .destructive, action: {
                        service.unpair(deviceId: device.deviceId)
                    }) {
                        Label("Unpair Device", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

// MARK: - Media Detail View

struct MediaDetailView: View {
    @ObservedObject var mediaPlugin = TetherService.shared.mediaControlPlugin
    @ObservedObject var remoteVolumePlugin = TetherService.shared.remoteVolumePlugin
    @ObservedObject var service = TetherService.shared

    var body: some View {
        VStack(spacing: 24) {
            let activeDevice = service.connectedDevices.first(where: { !$0.value.isDisconnected && $0.value.pairState == .paired })

            if let active = activeDevice {
                let deviceId = active.key
                let deviceName = active.value.peerDeviceInfo?.deviceName ?? "Phone"
                let state = mediaPlugin.nowPlaying[deviceId]

                VStack(spacing: 20) {
                    // Album art or placeholder
                    if let artData = mediaPlugin.albumArt[deviceId], let image = NSImage(data: artData) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 160, height: 160)
                            .cornerRadius(12)
                            .shadow(radius: 6)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(width: 160, height: 160)
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }

                    // Title & Artist
                    VStack(spacing: 6) {
                        Text(state?.title ?? "No Media Playing")
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        Text(state?.artist ?? deviceName)
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        if let album = state?.album, !album.isEmpty {
                            Text(album)
                                .font(.subheadline)
                                .foregroundColor(.secondary.opacity(0.8))
                                .lineLimit(1)
                        }
                    }

                    // Controls
                    HStack(spacing: 24) {
                        Button(action: {
                            service.mediaAction("Previous", deviceId: deviceId)
                        }) {
                            Image(systemName: "backward.fill")
                                .font(.title)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            service.mediaAction("PlayPause", deviceId: deviceId)
                        }) {
                            Image(systemName: (state?.isPlaying ?? false) ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 52))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            service.mediaAction("Next", deviceId: deviceId)
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.title)
                        }
                        .buttonStyle(.plain)
                    }

                    // Volume slider
                    if let sink = remoteVolumePlugin.sinks[deviceId]?.first(where: { $0.enabled }) ?? remoteVolumePlugin.sinks[deviceId]?.first {
                        HStack(spacing: 12) {
                            Image(systemName: sink.muted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                                .foregroundColor(.secondary)

                            Slider(
                                value: Binding(
                                    get: { Double(sink.volume) },
                                    set: { service.setPhoneVolume(Int($0), deviceId: deviceId) }
                                ),
                                in: 0...Double(max(sink.maxVolume, 100))
                            )
                            .frame(maxWidth: 300)

                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(40)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No Connected Device")
                        .font(.title3.weight(.medium))
                    Text("Connect your phone to control media playback.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Now Playing")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
