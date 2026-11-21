//
//  DeviceDetailView.swift
//  Tether
//
//  Right-hand side of the main window for one device, plus the states shown
//  when that device is nearby-but-unpaired, offline, or when there are none.
//

import SwiftUI

struct DeviceDetailView: View {
    @Bindable var device: DeviceViewModel
    let appModel: TetherAppModel
    let section: DeviceSection
    let onSelectSection: (DeviceSection) -> Void
    let onConnectByIP: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        Group {
            switch device.status {
            case .connected:
                connectedContent
            case .available:
                NearbyDeviceView(device: device)
            case .offline:
                OfflineDeviceView(device: device, appModel: appModel, onConnectByIP: onConnectByIP)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(device.isConnected ? section.title : device.name)
        // The sidebar says where you are; a title here only competes with
        // the content, and runs into it now that content passes underneath.
        .toolbar(removing: .title)
        // No band behind the toolbar: content runs up under it on every page.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var connectedContent: some View {
        VStack(spacing: 0) {
            if appModel.isNotificationPermissionDenied {
                NotificationPermissionBanner { appModel.openNotificationSettings() }
            }

            switch section {
            case .overview: OverviewPane(device: device, onSelectSection: onSelectSection)
            case .messages: MessagesPane(device: device)
            case .notifications: NotificationsPane(device: device)
            case .files: FilesPane(device: device)
            case .commands: CommandsPane(device: device)
            }
        }
        // Files dropped anywhere on a connected device's page are sent to it.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            device.sendFiles(files)
            onSelectSection(.files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                DropOverlay(deviceName: device.name)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }
}

private struct DropOverlay: View {
    let deviceName: String

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.tint, lineWidth: 3)
            .background(.tint.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottom) {
                Text("Drop to send to \(deviceName)")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar, in: .capsule)
                    .padding(.bottom, 24)
            }
            .padding(6)
            .allowsHitTesting(false)
    }
}

struct NotificationPermissionBanner: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(.orange)
            Text("Notifications are turned off for Tether, so phone alerts and replies won't appear on this Mac.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Turn On…", action: openSettings)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Nearby (unpaired)

struct NearbyDeviceView: View {
    @Bindable var device: DeviceViewModel

    var body: some View {
        VStack(spacing: 18) {
            DeviceHero(type: device.deviceType, isActive: device.status != .offline)

            VStack(spacing: 6) {
                Text(device.name)
                    .font(.title.bold())
                Text("Nearby on your network")
                    .foregroundStyle(.secondary)
            }

            if device.isAwaitingPairing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Accept the request on \(device.name) to finish pairing.")
                        .foregroundStyle(.secondary)
                }
                .frame(height: 64)
            } else {
                Button {
                    device.pair()
                } label: {
                    Text("Pair")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(height: 64)
            }

            Text("Pairing lets this Mac and \(device.name) share notifications, messages, files and the clipboard. Data stays on your local network and is encrypted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 380)
        .padding(32)
        .task(id: device.isAwaitingPairing) {
            // The phone may ignore the request; don't spin forever.
            guard device.isAwaitingPairing else { return }
            try? await Task.sleep(for: .seconds(30))
            device.isAwaitingPairing = false
        }
    }
}

// MARK: - Offline (paired, not reachable)

struct OfflineDeviceView: View {
    let device: DeviceViewModel
    let appModel: TetherAppModel
    let onConnectByIP: () -> Void

    @State private var isConfirmingUnpair = false

    var body: some View {
        VStack(spacing: 18) {
            DeviceHero(type: device.deviceType, isActive: device.status != .offline)

            VStack(spacing: 6) {
                Text(device.name)
                    .font(.title.bold())
                Text(device.statusLine)
                    .foregroundStyle(.secondary)
            }

            Text("Open KDE Connect on \(device.name) and make sure it's on the same Wi-Fi as this Mac, or that both are connected to Tailscale. It reconnects automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Look Again") { appModel.refreshDiscovery() }
                Button("Connect by Address…", action: onConnectByIP)
            }
            .controlSize(.large)

            Button("Unpair…", role: .destructive) { isConfirmingUnpair = true }
                .buttonStyle(.link)
                .foregroundStyle(.red)
                .padding(.top, 8)
        }
        .frame(maxWidth: 380)
        .padding(32)
        .confirmationDialog("Unpair \(device.name)?", isPresented: $isConfirmingUnpair) {
            Button("Unpair", role: .destructive) { device.unpair() }
        } message: {
            Text("You'll need to pair again from \(device.name) to reconnect.")
        }
    }
}

// MARK: - First run

struct OnboardingView: View {
    let appModel: TetherAppModel
    let onConnectByIP: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image("TetherLogo")
                    .resizable()
                    .frame(width: 84, height: 84)
                    .clipShape(.rect(cornerRadius: 19, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    .accessibilityHidden(true)
                Text("Connect Your Android Phone")
                    .font(.largeTitle.bold())
                Text("Tether works with the free KDE Connect app.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                step(1, "Install KDE Connect on your phone", detail: {
                    HStack(spacing: 12) {
                        Link("Google Play", destination: URL(string: "https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp")!)
                        Link("F-Droid", destination: URL(string: "https://f-droid.org/packages/org.kde.kdeconnect_tp/")!)
                    }
                })
                step(2, "Join the same Wi-Fi network as this Mac", detail: { EmptyView() })
                step(3, "In KDE Connect, tap “\(DeviceIdentity.shared.deviceName)” and request pairing", detail: { EmptyView() })
            }
            .frame(width: 400, alignment: .leading)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…")
                        .foregroundStyle(.secondary)
                }
                Button("Phone not showing up? Connect by Address…", action: onConnectByIP)
                    .buttonStyle(.link)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Tether")
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "\(number).circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityLabel("Step \(number)")
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                detail()
            }
        }
    }
}

// MARK: - Sheets

struct PairRequestSheet: View {
    let request: PairRequestViewModel
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            DeviceHero(type: request.deviceType, isActive: true)

            VStack(spacing: 6) {
                Text("Pair with \(request.deviceName)?")
                    .font(.title2.bold())
                Text("Only accept if you just started pairing on \(request.deviceName).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let fingerprint = request.fingerprint {
                VStack(spacing: 6) {
                    Text("Device certificate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        ForEach(FingerprintFormat.rows(fingerprint), id: \.self) { row in
                            Text(row)
                        }
                    }
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 12) {
                Button(role: .cancel, action: onDecline) {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)

                Button(action: onAccept) {
                    Text("Pair").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}

struct ConnectByIPSheet: View {
    /// Resolves and adds the address; false if it couldn't be resolved.
    let onConnect: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isResolving = false
    @State private var failedAddress: String?
    @FocusState private var isFocused: Bool

    private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// An IPv4 address or a host name such as a Tailscale MagicDNS name.
    private var isPlausible: Bool {
        guard !trimmed.isEmpty, trimmed.count <= 253, !trimmed.hasPrefix("."), !trimmed.hasSuffix("..") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect by Address")
                    .font(.title3.bold())
                Text("Use your phone's Wi-Fi IP address (Settings › About phone › Status), or its Tailscale address or name to connect from anywhere.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Address", text: $address, prompt: Text("192.168.1.45 or phone.tailnet.ts.net"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .onSubmit(connect)
                    .onChange(of: address) { failedAddress = nil }

                if let failedAddress {
                    Text("Couldn't find “\(failedAddress)”. Check the address, and that Tailscale is connected if you're using it.")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if isResolving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isPlausible || isResolving)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { isFocused = true }
    }

    private func connect() {
        guard isPlausible, !isResolving else { return }
        let target = trimmed
        isResolving = true
        Task {
            let added = await onConnect(target)
            isResolving = false
            if added {
                dismiss()
            } else {
                failedAddress = target
            }
        }
    }
}
