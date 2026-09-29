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

            remoteInputTab
                .tabItem {
                    Label("Remote Input", systemImage: "cursorarrow.rays")
                }

            devicesTab
                .tabItem {
                    Label("Devices", systemImage: "iphone.and.arrow.forward")
                }
        }
        .frame(width: 500, height: 350)
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

    @State private var isAccessibilityTrusted = InputSynthesizer.shared.isAccessibilityTrusted

    private var remoteInputTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remote Input & Presentation")
                .font(.headline)

            Text("Allow connected phones to use your Mac trackpad, mouse clicks, scrolling, keyboard input, and the presentation laser pointer overlay.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: isAccessibilityTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(isAccessibilityTrusted ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility Permission")
                                .font(.body.weight(.medium))
                            Text(isAccessibilityTrusted ? "Granted. Mouse and keyboard control are active." : "Required for controlling cursor and typing.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(isAccessibilityTrusted ? "Active" : "Not Granted")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isAccessibilityTrusted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                            .foregroundColor(isAccessibilityTrusted ? .green : .orange)
                            .cornerRadius(6)
                    }

                    Divider()

                    HStack(spacing: 12) {
                        Button("Check / Request Access") {
                            InputSynthesizer.shared.promptAccessibilityPermission()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                isAccessibilityTrusted = InputSynthesizer.shared.isAccessibilityTrusted
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button("Open System Settings") {
                            InputSynthesizer.shared.openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        Spacer()
                    }
                }
                .padding(8)
            }

            Spacer()
        }
        .onAppear {
            isAccessibilityTrusted = InputSynthesizer.shared.isAccessibilityTrusted
        }
    }
}
