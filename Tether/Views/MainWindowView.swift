//
//  MainWindowView.swift
//  Tether
//
//  AirSync-inspired native macOS SwiftUI main window interface.
//  Features an interactive phone mockup in the sidebar, modern glass cards,
//  notification permission warnings, drag-and-drop transfers, and tabbed plugin views.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Plugin Sections

public enum PluginSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case notifications = "Notifications"
    case transfers = "Transfers"
    case input = "Remote Input"
    case messages = "Messages"
    case commands = "Commands"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .overview: return "slider.horizontal.3"
        case .notifications: return "bell.badge"
        case .transfers: return "arrow.up.arrow.down"
        case .input: return "cursorarrow.rays"
        case .messages: return "bubble.left.and.bubble.right"
        case .commands: return "terminal"
        }
    }
}

// MARK: - Main Window View

public struct MainWindowView: View {
    @Bindable var appModel: TetherAppModel
    @State private var showingAddIPSheet: Bool = false
    @State private var manualIPInput: String = ""

    public init(appModel: TetherAppModel = TetherAppModel.shared) {
        self.appModel = appModel
    }

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let pairReq = appModel.incomingPairRequest {
                    mainWindowPairingBanner(for: pairReq)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let device = appModel.selectedDevice {
                    DeviceDetailView(device: device, appModel: appModel)
                        .id(device.id)
                } else {
                    emptyDetailState
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appModel.incomingPairRequest?.id)
        }
        .frame(minWidth: 880, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button {
                        manualIPInput = ""
                        showingAddIPSheet = true
                    } label: {
                        Label("Add by IP", systemImage: "network")
                    }
                    .help("Directly connect to a device by its local IP address")

                    Button {
                        appModel.refreshDiscovery()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Search for devices on the local network")
                }
            }
        }
        .sheet(isPresented: $showingAddIPSheet) {
            addDeviceByIPSheet
        }
        .onAppear {
            appModel.checkNotificationStatus()
        }
    }

    // MARK: - Sidebar Content
    private var sidebarContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Top Header / Device Switcher
                sidebarHeader

                // Centerpiece: Phone Mockup or Discovery Radar
                if let device = appModel.selectedDevice {
                    if device.status == .connected {
                        PhoneMockupView(device: device)
                            .padding(.vertical, 4)
                    } else if device.status == .available {
                        availableDeviceCard(for: device)
                    } else {
                        offlineDeviceCard(for: device)
                    }
                } else {
                    discoveryRadarCard
                }

                // Other Devices List
                if otherDevicesCount > 0 {
                    otherDevicesDrawer
                }

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
        .background(.background.opacity(0.85))
    }

    // MARK: - Sidebar Header
    private var sidebarHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "iphone.gen3.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)

            if appModel.allDevices.count > 1 {
                Menu {
                    ForEach(appModel.allDevices) { dev in
                        Button {
                            appModel.selectedDeviceId = dev.id
                        } label: {
                            HStack {
                                Text(dev.name)
                                if dev.id == appModel.selectedDeviceId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(appModel.selectedDevice?.name ?? "Devices")
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
            } else {
                Text(appModel.selectedDevice?.name ?? "Tether")
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
            }

            Spacer()

            if let device = appModel.selectedDevice {
                Circle()
                    .fill(device.status.color)
                    .frame(width: 8, height: 8)
                    .shadow(color: device.status.color.opacity(device.status == .connected ? 0.6 : 0), radius: 3)
            }
        }
        .padding(.horizontal, 6)
    }

    private var otherDevicesCount: Int {
        let currentId = appModel.selectedDeviceId
        return appModel.allDevices.filter { $0.id != currentId }.count
    }

    // MARK: - Other Devices Drawer
    private var otherDevicesDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OTHER DEVICES")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            ForEach(appModel.allDevices.filter { $0.id != appModel.selectedDeviceId }) { dev in
                Button {
                    appModel.selectedDeviceId = dev.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: dev.deviceType.systemImageName)
                            .font(.system(size: 13))
                            .foregroundColor(dev.status == .connected ? .accentColor : .secondary)

                        Text(dev.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)

                        Spacer()

                        if dev.status == .available {
                            Button("Pair") {
                                dev.pair()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        } else {
                            Circle()
                                .fill(dev.status.color)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - In-Window Pairing Banner
    @ViewBuilder
    private func mainWindowPairingBanner(for request: PairRequestViewModel) -> some View {
        GlassCard(cornerRadius: 16, paddingAmount: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Pairing Request")
                            .font(.system(size: 14, weight: .bold))
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(request.deviceName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    if let fp = request.fingerprint {
                        Text("Verification Key: \(fp.prefix(28))...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("This device wants to connect to your Mac.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Reject", role: .destructive) {
                        withAnimation {
                            appModel.rejectIncomingPairRequest()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button("Accept Pairing") {
                        withAnimation {
                            appModel.acceptIncomingPairRequest()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
    }

    // MARK: - Add Device By IP Sheet
    private var addDeviceByIPSheet: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.accentColor)
                Text("Connect by IP Address")
                    .font(.headline)
                Spacer()
            }

            Text("Enter your phone or tablet's local Wi-Fi IP address (e.g. 192.168.1.45) to connect directly if your router filters discovery broadcasts.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)

            TextField("e.g. 192.168.1.45", text: $manualIPInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack {
                Button("Cancel") {
                    showingAddIPSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Connect") {
                    let ip = manualIPInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ip.isEmpty {
                        appModel.addManualPeer(ip: ip)
                    }
                    showingAddIPSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(manualIPInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Available Device Card
    @ViewBuilder
    private func availableDeviceCard(for device: DeviceViewModel) -> some View {
        GlassCard(cornerRadius: 20, paddingAmount: 20) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundColor(.blue)
                }

                VStack(spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                    Text("Discovered on local Wi-Fi")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button {
                    device.pair()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text("Pair with Mac")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(width: 200)
        }
    }

    // MARK: - Offline Device Card
    @ViewBuilder
    private func offlineDeviceCard(for device: DeviceViewModel) -> some View {
        GlassCard(cornerRadius: 20, paddingAmount: 20) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 60, height: 60)
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                    Text("Currently Offline")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Unpair") {
                    device.unpair()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(width: 200)
        }
    }

    // MARK: - Discovery Radar Card
    private var discoveryRadarCard: some View {
        GlassCard(cornerRadius: 20, paddingAmount: 24) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 2)
                        .frame(width: 70, height: 70)
                    Circle()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 50, height: 50)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 4) {
                    Text("Looking for Devices...")
                        .font(.subheadline.weight(.semibold))
                    Text("Ensure KDE Connect is running on your phone and on the same Wi-Fi.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    appModel.refreshDiscovery()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(width: 200)
        }
    }

    // MARK: - Empty Detail State
    private var emptyDetailState: some View {
        ContentUnavailableView(
            "Select a Device",
            systemImage: "iphone.gen3",
            description: Text("Choose a device from the sidebar to view details, file sharing, notifications, and remote controls.")
        )
    }
}

// MARK: - Device Detail View

public struct DeviceDetailView: View {
    @Bindable var device: DeviceViewModel
    var appModel: TetherAppModel
    @State private var selectedSection: PluginSection = .overview

    public init(device: DeviceViewModel, appModel: TetherAppModel = TetherAppModel.shared) {
        self.device = device
        self.appModel = appModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Notification Permission Warning Banner (if macOS alerts are off)
            if appModel.isNotificationPermissionDenied {
                notificationPermissionWarningBanner
            }

            // Top Header Banner
            detailHeaderBanner

            Divider()

            // Modern Segmented Tab Switcher
            tabSwitcher
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            // Active Tab Content
            switch selectedSection {
            case .overview:
                DeviceOverviewTab(device: device)
            case .notifications:
                DeviceNotificationsTab(device: device, appModel: appModel)
            case .transfers:
                DeviceTransfersTab(device: device)
            case .input:
                DeviceRemoteInputTab(device: device)
            case .messages:
                DeviceMessagesTab(device: device)
            case .commands:
                DeviceCommandsTab(device: device)
            }
        }
    }

    // MARK: - Notification Permission Warning Banner
    private var notificationPermissionWarningBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are Disabled in macOS")
                    .font(.system(size: 12, weight: .semibold))
                Text("Tether cannot deliver phone alerts or inline replies because notifications are turned off in System Settings.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Open System Settings") {
                appModel.openNotificationSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .overlay(
            Rectangle()
                .fill(Color.orange.opacity(0.35))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Detail Header Banner
    private var detailHeaderBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.10))
                    .frame(width: 48, height: 48)
                Image(systemName: device.deviceType.systemImageName)
                    .font(.system(size: 22))
                    .foregroundColor(device.status == .connected ? .accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(.title3.weight(.bold))

                    Text(device.status.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(device.status.color.opacity(0.15))
                        .foregroundColor(device.status.color)
                        .clipShape(Capsule())
                }

                HStack(spacing: 14) {
                    if let batt = device.batteryPercent {
                        HStack(spacing: 4) {
                            Image(systemName: device.isCharging ? "battery.100bolt" : "battery.100")
                                .foregroundColor(batt <= 20 ? .red : (device.isCharging ? .accentColor : .secondary))
                            Text("\(batt)%")
                                .font(.caption.monospacedDigit())
                        }
                    }

                    if let net = device.networkType {
                        HStack(spacing: 4) {
                            Image(systemName: "wifi")
                                .foregroundColor(.secondary)
                            Text(net)
                                .font(.caption)
                        }
                    }

                    Text("ID: \(device.id.prefix(8))...")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if device.status == .connected {
                HStack(spacing: 8) {
                    GlassButtonView(
                        label: "Ping",
                        systemImage: "bell.badge",
                        size: .small
                    ) {
                        device.ping()
                    }

                    GlassButtonView(
                        label: "Ring",
                        systemImage: "speaker.wave.3",
                        size: .small
                    ) {
                        device.findMyPhone()
                    }

                    GlassButtonView(
                        label: "Lock",
                        systemImage: "lock",
                        size: .small
                    ) {
                        device.lockDevice()
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Tab Switcher
    private var tabSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(PluginSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: section.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(section.rawValue)
                            .font(.system(size: 12, weight: .medium))

                        if section == .notifications && !device.notifications.isEmpty {
                            Text("\(device.notifications.count)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(selectedSection == section ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.clear))
                    )
                    .overlay(
                        Capsule()
                            .stroke(selectedSection == section ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
                    .foregroundColor(selectedSection == section ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - Overview Tab

public struct DeviceOverviewTab: View {
    @Bindable var device: DeviceViewModel

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Now Playing Card (if active)
                if let title = device.nowPlayingTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    GlassCard(cornerRadius: 16, paddingAmount: 16) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.2))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "music.note")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(.accentColor)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)
                                if let artist = device.nowPlayingArtist, !artist.isEmpty {
                                    Text(artist)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            HStack(spacing: 10) {
                                Button {
                                    device.previousMedia()
                                } label: {
                                    Image(systemName: "backward.fill")
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    device.playPauseMedia()
                                } label: {
                                    Image(systemName: device.nowPlayingIsPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button {
                                    device.nextMedia()
                                } label: {
                                    Image(systemName: "forward.fill")
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                // Remote Volume Card
                if device.status == .connected {
                    GlassCard(cornerRadius: 16, paddingAmount: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Remote Device Volume")
                                .font(.subheadline.weight(.semibold))

                            HStack(spacing: 12) {
                                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .foregroundColor(device.isMuted ? .secondary : .accentColor)
                                    .frame(width: 20)

                                Slider(value: Binding(
                                    get: { device.volume },
                                    set: { device.setVolume($0) }
                                ), in: 0...1)

                                Text("\(Int(device.volume * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }

                // Quick Actions Grid
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick Controls")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                        quickActionButton(title: "Ping Device", icon: "bell.badge", disabled: device.status != .connected) {
                            device.ping()
                        }
                        quickActionButton(title: "Ring Phone", icon: "speaker.wave.3.fill", disabled: device.status != .connected) {
                            device.findMyPhone()
                        }
                        quickActionButton(title: "Lock Screen", icon: "lock.fill", disabled: device.status != .connected) {
                            device.lockDevice()
                        }
                        quickActionButton(title: "Push Clipboard", icon: "doc.on.clipboard.fill", disabled: device.status != .connected) {
                            device.sendClipboard()
                        }
                    }
                }

                Spacer()
            }
            .padding(18)
        }
    }

    private func quickActionButton(title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(disabled ? .secondary : .accentColor)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1.0)
    }
}

// MARK: - Notifications Tab

public struct DeviceNotificationsTab: View {
    @Bindable var device: DeviceViewModel
    var appModel: TetherAppModel

    @State private var replyingToId: String? = nil
    @State private var replyText: String = ""

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Notifications (\(device.notifications.count))")
                    .font(.headline)
                Spacer()
                if !device.notifications.isEmpty {
                    Button("Dismiss All") {
                        for notif in device.notifications {
                            device.dismissNotification(id: notif.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            if device.notifications.isEmpty {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell.slash",
                    description: Text("Alerts and messages received from \(device.name) will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(device.notifications) { notif in
                            notificationCard(for: notif)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    @ViewBuilder
    private func notificationCard(for notif: DeliveredNotificationItem) -> some View {
        GlassCard(cornerRadius: 14, paddingAmount: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "app.badge")
                            .font(.system(size: 15))
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(notif.appName)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(notif.date, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text(notif.title)
                            .font(.system(size: 13, weight: .semibold))

                        Text(notif.body)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button {
                        device.dismissNotification(id: notif.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss on phone")
                }

                // Inline quick reply field (if replying)
                if replyingToId == notif.id {
                    HStack(spacing: 8) {
                        TextField("Type reply...", text: $replyText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                sendReply(for: notif)
                            }

                        Button("Send") {
                            sendReply(for: notif)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel") {
                            replyingToId = nil
                            replyText = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                } else if notif.replyId != nil {
                    Button {
                        replyingToId = notif.id
                        replyText = ""
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func sendReply(for notif: DeliveredNotificationItem) {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Broadcast reply or SMS
        device.sendSMS(to: notif.appName, message: text)
        replyingToId = nil
        replyText = ""
    }
}

// MARK: - Transfers Tab

public struct DeviceTransfersTab: View {
    @Bindable var device: DeviceViewModel
    @State private var isDropTarget: Bool = false

    public var body: some View {
        VStack(spacing: 0) {
            // Drag and drop zone card
            dropZoneCard
                .padding(16)

            Divider()

            // Recent transfers list
            if device.transfers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No Transfers Yet")
                        .font(.subheadline.weight(.medium))
                    Text("Transferred files will appear here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(device.transfers) { item in
                            transferItemCard(for: item)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDroppedFiles(providers)
        }
    }

    private var dropZoneCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(isDropTarget ? 0.25 : 0.12))
                    .frame(width: 54, height: 54)
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
            }

            VStack(spacing: 4) {
                Text("Drop files here to send to \(device.name)")
                    .font(.system(size: 13, weight: .semibold))
                Text("or click to choose files from Finder")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button {
                openSendFileDialog()
            } label: {
                Label("Browse Files...", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isDropTarget ? Color.accentColor : Color.secondary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
    }

    @ViewBuilder
    private func transferItemCard(for item: TransferItem) -> some View {
        GlassCard(cornerRadius: 12, paddingAmount: 12) {
            HStack(spacing: 12) {
                Image(systemName: item.direction == .incoming ? "arrow.down.doc.fill" : "arrow.up.doc.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if item.status == .transferring {
                            Text("\(Int(item.progress * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.accentColor)
                        }
                    }

                    if item.status == .transferring {
                        ProgressView(value: item.progress)
                            .progressViewStyle(.linear)
                    }
                }

                Spacer()

                switch item.status {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .failed(let reason):
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .help(reason)
                case .transferring:
                    ProgressView()
                        .controlSize(.small)
                case .queued:
                    Text("Queued")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                case .cancelled:
                    Text("Cancelled")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func openSendFileDialog() {
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
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        device.sendFile(url: url)
                    }
                } else if let url = item as? URL {
                    DispatchQueue.main.async {
                        device.sendFile(url: url)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Remote Input Tab

public struct DeviceRemoteInputTab: View {
    @Bindable var device: DeviceViewModel
    @State private var isAccessibilityTrusted: Bool = InputSynthesizer.shared.isAccessibilityTrusted
    @State private var laserPointerActive: Bool = false

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Input & Presentation")
                        .font(.headline)
                    Text("\(device.name) can act as a wireless trackpad, keyboard, and slide laser pointer.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // Virtual Trackpad Card
                GlassCard(cornerRadius: 16, paddingAmount: 20) {
                    VStack(spacing: 12) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.accentColor)

                        Text("Wireless Trackpad Ready")
                            .font(.system(size: 14, weight: .semibold))

                        Text("Open the Remote Input tool in KDE Connect on your phone to control the mouse pointer and enter text.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                // Laser Pointer Card
                GlassCard(cornerRadius: 16, paddingAmount: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Virtual Laser Pointer")
                                .font(.subheadline.weight(.semibold))
                            Text("Shows a high-visibility pointer dot on screen during presentations.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $laserPointerActive)
                            .toggleStyle(.switch)
                            .onChange(of: laserPointerActive) { _, active in
                                if active {
                                    PresenterOverlayWindowController.shared.update(xPos: 0.5, yPos: 0.5)
                                } else {
                                    PresenterOverlayWindowController.shared.hide()
                                }
                            }
                    }
                }

                // macOS Accessibility Card
                GlassCard(cornerRadius: 16, paddingAmount: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: isAccessibilityTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundColor(isAccessibilityTrusted ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(isAccessibilityTrusted ? "Accessibility Granted" : "Accessibility Permission Required")
                                .font(.subheadline.weight(.semibold))
                            Text(isAccessibilityTrusted ? "Tether is authorized to synthesize mouse and keyboard events." : "Enable Tether in System Settings > Privacy & Security > Accessibility.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Settings") {
                            InputSynthesizer.shared.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Spacer()
            }
            .padding(18)
        }
        .onAppear {
            isAccessibilityTrusted = InputSynthesizer.shared.isAccessibilityTrusted
        }
    }
}

// MARK: - Messages Tab

public struct DeviceMessagesTab: View {
    @Bindable var device: DeviceViewModel
    @State private var selectedThreadId: Int64?
    @State private var composeText: String = ""

    public var body: some View {
        if device.smsThreads.isEmpty {
            ContentUnavailableView(
                "No Messages",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("SMS threads from \(device.name) will appear here once synced.")
            )
        } else {
            NavigationSplitView {
                List(device.smsThreads, selection: $selectedThreadId) { thread in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(thread.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            if let last = thread.lastMessage {
                                Text(last.date, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let last = thread.lastMessage {
                            Text(last.body)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(thread.id)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 270)
            } detail: {
                if let threadId = selectedThreadId ?? device.smsThreads.first?.id,
                   let thread = device.smsThreads.first(where: { $0.id == threadId }) {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(thread.messages) { msg in
                                    HStack {
                                        if msg.isOutgoing { Spacer() }
                                        Text(msg.body)
                                            .font(.system(size: 13))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                    .fill(msg.isOutgoing ? Color.accentColor : Color.secondary.opacity(0.15))
                                            )
                                            .foregroundColor(msg.isOutgoing ? .white : .primary)
                                        if !msg.isOutgoing { Spacer() }
                                    }
                                }
                            }
                            .padding(16)
                        }

                        Divider()

                        HStack(spacing: 8) {
                            TextField("Type an SMS reply...", text: $composeText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    sendReply(to: thread)
                                }

                            Button("Send") {
                                sendReply(to: thread)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(12)
                    }
                } else {
                    ContentUnavailableView("Select a Conversation", systemImage: "bubble.left")
                }
            }
        }
    }

    private func sendReply(to thread: SMSConversation) {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let addr = thread.addresses.first else { return }
        device.sendSMS(to: addr, message: text)
        composeText = ""
    }
}

// MARK: - Commands Tab

public struct DeviceCommandsTab: View {
    @Bindable var device: DeviceViewModel

    public var body: some View {
        if device.commands.isEmpty {
            ContentUnavailableView(
                "No Commands Configured",
                systemImage: "terminal",
                description: Text("Shell commands configured in Tether can be run remotely from your phone.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(device.commands) { cmd in
                        GlassCard(cornerRadius: 14, paddingAmount: 14) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "terminal")
                                        .font(.system(size: 16))
                                        .foregroundColor(.accentColor)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cmd.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(cmd.command)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Button {
                                    device.executeCommand(id: cmd.id)
                                } label: {
                                    Label("Run", systemImage: "play.fill")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Previews

#Preview("Main Window - Connected Phone") {
    MainWindowView(appModel: .mock())
        .preferredColorScheme(.dark)
}

#Preview("Main Window - Empty State") {
    MainWindowView(appModel: .mockEmpty())
}
