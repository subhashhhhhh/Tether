//
//  MenuBarView.swift
//  Tether
//
//  Native macOS SwiftUI MenuBarExtra window view following Apple Design Guidelines.
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
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            Divider()

            if let pairReq = appModel.incomingPairRequest {
                pairingRequestBanner(for: pairReq)
                Divider()
            }

            pairedDevicesSection

            if !appModel.availableDevices.isEmpty {
                Divider()
                availableDevicesSection
            }

            Divider()

            footerSection
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDroppedFiles(providers)
        }
        .onAppear {
            appModel.refreshDiscovery()
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack(alignment: .center) {
            Label {
                Text("Tether")
                    .font(.headline)
            } icon: {
                Image(systemName: appModel.statusIconName)
                    .foregroundColor(appModel.connectedDevices.isEmpty ? .secondary : .accentColor)
            }
            .labelStyle(.titleAndIcon)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(appModel.connectedDevices.isEmpty ? (appModel.isRunning ? Color.blue : Color.secondary) : Color.green)
                    .frame(width: 7, height: 7)
                Text(appModel.connectedDevices.isEmpty ? (appModel.isRunning ? "Searching" : "Offline") : "Online")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(appModel.connectedDevices.isEmpty ? (appModel.isRunning ? "Searching for devices" : "Offline") : "Online")")

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Settings")
        }
    }

    // MARK: - Pairing Request Banner
    @ViewBuilder
    private func pairingRequestBanner(for request: PairRequestViewModel) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pairing Request")
                            .font(.subheadline.weight(.semibold))
                        Text("\(request.deviceName) wants to connect")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let fp = request.fingerprint {
                    Text("Fingerprint: \(fp.prefix(23))...")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
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
            .padding(4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Incoming pairing request from \(request.deviceName)")
    }

    // MARK: - Paired Devices
    private var pairedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PAIRED DEVICES")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            let pairedCount = appModel.connectedDevices.count + appModel.offlineDevices.count
            if pairedCount == 0 {
                VStack(spacing: 6) {
                    Image(systemName: "iphone.slash")
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    Text("No paired devices")
                        .font(.subheadline.weight(.medium))
                    Text("Open KDE Connect on your phone to pair.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(appModel.connectedDevices) { device in
                    connectedDeviceRow(for: device)
                }
                ForEach(appModel.offlineDevices) { device in
                    offlineDeviceRow(for: device)
                }
            }
        }
    }

    // MARK: - Connected Device Row & Quick Actions
    @ViewBuilder
    private func connectedDeviceRow(for device: DeviceViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label {
                    Text(device.name)
                        .font(.body.weight(.medium))
                } icon: {
                    Image(systemName: device.deviceType.systemImageName)
                        .foregroundColor(.accentColor)
                }
                .labelStyle(.titleAndIcon)

                Spacer()

                if let batt = device.batteryPercent {
                    HStack(spacing: 3) {
                        Image(systemName: device.isCharging ? "battery.100bolt" : batteryIconName(for: batt))
                            .foregroundColor(batt < 20 ? .red : (device.isCharging ? .accentColor : .primary))
                        Text("\(batt)%")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Battery \(batt) percent\(device.isCharging ? ", charging" : "")")
                }

                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Connected")
            }

            // Quick Actions Bar
            HStack(spacing: 6) {
                Button {
                    device.ping()
                } label: {
                    Label("Ping", systemImage: "bell.badge")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Ping \(device.name)")

                Button {
                    openSendFileDialog(for: device)
                } label: {
                    Label("Send File", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Send file to \(device.name)")

                Button {
                    device.sendClipboard()
                } label: {
                    Label("Push Clip", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Send clipboard to \(device.name)")

                Menu {
                    Button {
                        device.findMyPhone()
                    } label: {
                        Label("Ring Phone", systemImage: "speaker.wave.3")
                    }

                    Button {
                        device.lockDevice()
                    } label: {
                        Label("Lock Screen", systemImage: "lock")
                    }

                    Divider()

                    Button("Unpair", role: .destructive) {
                        device.unpair()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
                .accessibilityLabel("More device actions")
            }
            .labelStyle(.iconOnly)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Offline Device Row
    @ViewBuilder
    private func offlineDeviceRow(for device: DeviceViewModel) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(device.name)
                    .font(.body)
                    .foregroundColor(.secondary)
            } icon: {
                Image(systemName: device.deviceType.systemImageName)
                    .foregroundColor(.secondary)
            }
            .labelStyle(.titleAndIcon)

            Spacer()

            Text("Offline")
                .font(.caption2)
                .foregroundColor(.secondary)

            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .accessibilityLabel("Offline")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Available Devices Section
    private var availableDevicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AVAILABLE NEARBY")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            ForEach(appModel.availableDevices) { device in
                HStack(spacing: 8) {
                    Label {
                        Text(device.name)
                            .font(.body)
                    } icon: {
                        Image(systemName: device.deviceType.systemImageName)
                            .foregroundColor(.blue)
                    }
                    .labelStyle(.titleAndIcon)

                    Spacer()

                    Button("Pair") {
                        device.pair()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Pair with \(device.name)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Footer
    private var footerSection: some View {
        HStack {
            Button("Open App") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityHint("Opens the main Tether management window")

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.callout)
            .accessibilityHint("Quits Tether")
        }
    }

    // MARK: - Helpers
    private func batteryIconName(for percent: Int) -> String {
        switch percent {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<65: return "battery.50"
        case ..<85: return "battery.75"
        default: return "battery.100"
        }
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

// MARK: - SwiftUI Previews

#Preview("Connected - Light Mode") {
    MenuBarView(appModel: .mock())
        .preferredColorScheme(.light)
}

#Preview("Connected - Dark Mode") {
    MenuBarView(appModel: .mock())
        .preferredColorScheme(.dark)
}

#Preview("Pending Pairing Request") {
    MenuBarView(appModel: .mockPairRequest())
}

#Preview("No Devices - Empty State") {
    MenuBarView(appModel: .mockEmpty())
}
