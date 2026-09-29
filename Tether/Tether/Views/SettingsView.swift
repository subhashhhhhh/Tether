//
//  SettingsView.swift
//  Tether
//

import SwiftUI

public struct SettingsView: View {
    @State private var deviceName: String = DeviceIdentity.shared.deviceName
    @ObservedObject var trustStore = TrustStore.shared
    @ObservedObject var service = TetherService.shared

    public init() {}

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            devicesTab
                .tabItem {
                    Label("Devices", systemImage: "iphone.and.arrow.forward")
                }
        }
        .frame(width: 480, height: 320)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section("Device Identity") {
                TextField("Device Name", text: $deviceName)
                    .onSubmit {
                        DeviceIdentity.shared.deviceName = deviceName
                        UserDefaults.standard.set(deviceName, forKey: "tether_device_name")
                    }

                LabeledContent("Device ID") {
                    Text(DeviceIdentity.shared.deviceId)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }

                LabeledContent("Certificate Fingerprint") {
                    Text(DeviceIdentity.shared.certificateFingerprint)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("Network Status") {
                LabeledContent("UDP Discovery Port", value: "1716")
                LabeledContent("Status", value: service.isRunning ? "Active & Broadcasting" : "Stopped")
            }
        }
    }

    private var devicesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trusted & Paired Devices")
                .font(.headline)

            if trustStore.pairedDevices.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No devices have been paired yet.")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Text("Open KDE Connect on your Android phone on the same Wi-Fi network to pair.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(Array(trustStore.pairedDevices.values)) { device in
                        HStack {
                            Image(systemName: device.deviceType.systemImageName)
                                .font(.title2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.deviceName)
                                    .font(.headline)
                                Text("Fingerprint: \(device.certificateFingerprint.prefix(23))...")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button("Unpair", role: .destructive) {
                                service.unpair(deviceId: device.deviceId)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}
