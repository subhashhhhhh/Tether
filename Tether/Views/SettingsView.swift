//
//  SettingsView.swift
//  Tether
//
//  Native macOS SwiftUI Settings view bound to @Observable SettingsViewModel.
//

import SwiftUI
import UserNotifications

public struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var editingDeviceName: String = ""

    public init(viewModel: SettingsViewModel = SettingsViewModel.shared) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            trustedDevicesTab
                .tabItem {
                    Label("Devices", systemImage: "iphone.and.arrow.forward")
                }

            notificationsTab
                .tabItem {
                    Label("Notifications", systemImage: "bell.badge")
                }

            accessibilityTab
                .tabItem {
                    Label("Remote Input", systemImage: "cursorarrow.rays")
                }
        }
        .frame(width: 520, height: 380)
        .padding()
        .onAppear {
            viewModel.refresh()
            editingDeviceName = viewModel.deviceName
        }
    }

    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section("Device Identity") {
                HStack {
                    TextField("Device Name", text: $editingDeviceName)
                        .onSubmit {
                            viewModel.saveDeviceName(editingDeviceName)
                        }

                    if editingDeviceName != viewModel.deviceName {
                        Button("Save") {
                            viewModel.saveDeviceName(editingDeviceName)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                LabeledContent("Device ID") {
                    Text(viewModel.deviceId)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }

                LabeledContent("Certificate Fingerprint") {
                    Text(viewModel.certificateFingerprint)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("Startup") {
                Toggle(isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch Tether at Login")
                            .font(.body)
                        Text("Starts the background service and menu bar item automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Network") {
                LabeledContent("Discovery Port", value: "1716 (UDP & TCP)")
                LabeledContent("Protocol Version", value: "KDE Connect v8")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Trusted Devices Tab
    private var trustedDevicesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trusted & Paired Devices")
                .font(.headline)

            if viewModel.pairedDevices.isEmpty {
                ContentUnavailableView(
                    "No Paired Devices",
                    systemImage: "iphone.slash",
                    description: Text("Open KDE Connect on your phone or tablet on the same Wi-Fi network to pair.")
                )
            } else {
                List {
                    ForEach(viewModel.pairedDevices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: device.deviceType.systemImageName)
                                .font(.title2)
                                .foregroundColor(.accentColor)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.deviceName)
                                    .font(.body.weight(.medium))

                                Text("Fingerprint: \(device.certificateFingerprint.prefix(23))...")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)

                                Text("Paired on \(device.pairedDate.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button("Unpair", role: .destructive) {
                                viewModel.unpair(deviceId: device.deviceId)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Unpair \(device.deviceName)")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Notifications Tab
    private var notificationsTab: some View {
        Form {
            Section("macOS Notification Delivery") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: notificationStatusIcon)
                            .font(.title2)
                            .foregroundColor(notificationStatusColor)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(notificationStatusTitle)
                                .font(.body.weight(.medium))

                            Text(notificationStatusDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(notificationStatusBadgeText)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(notificationStatusColor.opacity(0.15))
                            .foregroundColor(notificationStatusColor)
                            .clipShape(Capsule())
                    }

                    if viewModel.notificationAuthStatus == .denied {
                        HStack(spacing: 10) {
                            Button("Open Notification Settings") {
                                viewModel.openNotificationSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button {
                                viewModel.refreshNotificationStatus()
                            } label: {
                                Label("Refresh Status", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else if viewModel.notificationAuthStatus == .notDetermined {
                        Button("Request Notification Permission") {
                            viewModel.requestNotificationPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Phone Synchronization") {
                LabeledContent("Notification Mirroring") {
                    Text("Incoming phone notifications are synced over TLS")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                LabeledContent("Inline Reply") {
                    Text("Reply to phone SMS and chat notifications directly from macOS banners")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                LabeledContent("Notification Dismissal") {
                    Text("Dismissing a notification on Mac cancels it on your phone")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Accessibility Tab
    private var accessibilityTab: some View {
        Form {
            Section("Remote Trackpad & Keyboard Input") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: viewModel.isAccessibilityTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundColor(viewModel.isAccessibilityTrusted ? .green : .orange)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(viewModel.isAccessibilityTrusted ? "Accessibility Granted" : "Accessibility Permission Required")
                                .font(.body.weight(.medium))

                            Text(viewModel.isAccessibilityTrusted ?
                                 "Tether can simulate mouse cursor movement, clicks, scrolling, and keystrokes from your phone." :
                                 "macOS requires Accessibility access for Tether to control the cursor and keyboard.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(viewModel.isAccessibilityTrusted ? "Active" : "Disabled")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(viewModel.isAccessibilityTrusted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                            .foregroundColor(viewModel.isAccessibilityTrusted ? .green : .orange)
                            .clipShape(Capsule())
                    }

                    HStack(spacing: 10) {
                        if !viewModel.isAccessibilityTrusted {
                            Button("Prompt Permission") {
                                viewModel.promptAccessibility()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Button("Open Accessibility Settings") {
                            viewModel.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notification Status Helpers
    private var notificationStatusIcon: String {
        switch viewModel.notificationAuthStatus {
        case .authorized, .provisional: return "checkmark.seal.fill"
        case .denied: return "exclamationmark.triangle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var notificationStatusColor: Color {
        switch viewModel.notificationAuthStatus {
        case .authorized, .provisional: return .green
        case .denied: return .red
        default: return .orange
        }
    }

    private var notificationStatusTitle: String {
        switch viewModel.notificationAuthStatus {
        case .authorized, .provisional: return "Notifications Enabled"
        case .denied: return "Notifications Denied in System Settings"
        default: return "Permission Not Yet Requested"
        }
    }

    private var notificationStatusDescription: String {
        switch viewModel.notificationAuthStatus {
        case .authorized, .provisional:
            return "Tether can display banners, sounds, and badges when your phone receives alerts."
        case .denied:
            return "macOS is silencing Tether notifications. Open System Settings > Notifications to turn on 'Allow Notifications'."
        default:
            return "Click below to prompt macOS for notification authorization."
        }
    }

    private var notificationStatusBadgeText: String {
        switch viewModel.notificationAuthStatus {
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .denied: return "Denied"
        default: return "Not Determined"
        }
    }
}

// MARK: - SwiftUI Previews

#Preview("Settings - Authorized (Light)") {
    SettingsView(viewModel: .mock())
        .preferredColorScheme(.light)
}

#Preview("Settings - Authorized (Dark)") {
    SettingsView(viewModel: .mock())
        .preferredColorScheme(.dark)
}

#Preview("Settings - Notifications Denied (Error State)") {
    SettingsView(viewModel: .mockDenied())
}
