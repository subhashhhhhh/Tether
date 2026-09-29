//
//  MenuBarView.swift
//  KDEConnect
//

import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var service = KDEConnectService.shared
    @ObservedObject var trustStore = TrustStore.shared
    @ObservedObject var batteryPlugin: BatteryPlugin
    @Environment(\.openSettings) private var openSettings

    public init() {
        self.batteryPlugin = KDEConnectService.shared.batteryPlugin
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

            Divider()

            // Footer
            HStack {
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
    }

    @ViewBuilder
    private func deviceRow(for device: PairedDevice) -> some View {
        let isConnected = service.connectedDevices[device.deviceId] != nil
        let battery = batteryPlugin.deviceBatteries[device.deviceId]

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: device.deviceType.systemImageName)
                    .foregroundColor(isConnected ? .primary : .secondary)

                Text(device.deviceName)
                    .font(.body)
                    .foregroundColor(isConnected ? .primary : .secondary)

                Spacer()

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
                HStack(spacing: 8) {
                    Button(action: {
                        service.sendPing(to: device.deviceId)
                    }) {
                        Label("Ping", systemImage: "bell.badge")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Spacer()

                    Menu {
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
            }
        }
        .padding(.vertical, 4)
    }
}
