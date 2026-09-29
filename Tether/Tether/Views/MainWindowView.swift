//
//  MainWindowView.swift
//  Tether
//
//  Main application window with two-column NavigationSplitView, device grouping,
//  TabsPickerStyle plugin switcher, and full modern macOS design system compliance.
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

    public init(appModel: TetherAppModel = TetherAppModel.shared) {
        self.appModel = appModel
    }

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            if let device = appModel.selectedDevice {
                DeviceDetailView(device: device)
                    .id(device.id)
            } else {
                ContentUnavailableView(
                    "Select a Device",
                    systemImage: "sidebar.left",
                    description: Text("Choose a device from the sidebar to view details, controls, and plugins.")
                )
            }
        }
        .frame(minWidth: 840, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appModel.refreshDiscovery()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Search for devices on the local network")
            }
        }
    }

    // MARK: - Sidebar Content
    private var sidebarContent: some View {
        List(selection: $appModel.selectedDeviceId) {
            if !appModel.filteredConnectedDevices.isEmpty {
                Section("Connected") {
                    ForEach(appModel.filteredConnectedDevices) { device in
                        sidebarDeviceRow(for: device)
                            .tag(device.id)
                    }
                }
            }

            if !appModel.filteredAvailableDevices.isEmpty {
                Section("Available Nearby") {
                    ForEach(appModel.filteredAvailableDevices) { device in
                        sidebarAvailableRow(for: device)
                            .tag(device.id)
                    }
                }
            }

            if !appModel.filteredOfflineDevices.isEmpty {
                Section("Offline") {
                    ForEach(appModel.filteredOfflineDevices) { device in
                        sidebarDeviceRow(for: device)
                            .tag(device.id)
                    }
                }
            }

            if appModel.allDevices.isEmpty {
                ContentUnavailableView(
                    "No Devices",
                    systemImage: "iphone.slash",
                    description: Text("Make sure KDE Connect is running on your phone and connected to the same Wi-Fi network.")
                )
            } else if appModel.filteredConnectedDevices.isEmpty &&
                        appModel.filteredAvailableDevices.isEmpty &&
                        appModel.filteredOfflineDevices.isEmpty {
                ContentUnavailableView.search(text: appModel.searchText)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $appModel.searchText, prompt: "Search devices...")
        .navigationTitle("Devices")
    }

    @ViewBuilder
    private func sidebarDeviceRow(for device: DeviceViewModel) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(device.name)
                    .lineLimit(1)
            } icon: {
                Image(systemName: device.deviceType.systemImageName)
                    .foregroundColor(device.status == .connected ? .accentColor : .secondary)
            }
            .labelStyle(.titleAndIcon)

            Spacer()

            if let batt = device.batteryPercent, device.status == .connected {
                HStack(spacing: 3) {
                    Image(systemName: device.isCharging ? "battery.100bolt" : "battery.100")
                        .foregroundColor(batt < 20 ? .red : (device.isCharging ? .accentColor : .secondary))
                    Text("\(batt)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            Circle()
                .fill(device.status.color)
                .frame(width: 8, height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name), \(device.deviceType.rawValue), \(device.status.rawValue)")
    }

    @ViewBuilder
    private func sidebarAvailableRow(for device: DeviceViewModel) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(device.name)
                    .lineLimit(1)
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
            .controlSize(.mini)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name), Available to pair")
    }
}

// MARK: - Device Detail View

public struct DeviceDetailView: View {
    @Bindable var device: DeviceViewModel
    @State private var selectedSection: PluginSection = .overview

    public init(device: DeviceViewModel) {
        self.device = device
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBanner

            Divider()

            // Tab-style picker using TabsPickerStyle
            Picker("Section", selection: $selectedSection) {
                ForEach(PluginSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            .pickerStyle(.tabs)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Active Tab Content
            switch selectedSection {
            case .overview:
                DeviceOverviewTab(device: device)
            case .notifications:
                DeviceNotificationsTab(device: device)
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

    // MARK: - Header Banner
    private var headerBanner: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 50, height: 50)
                Image(systemName: device.deviceType.systemImageName)
                    .font(.title)
                    .foregroundColor(device.status == .connected ? .accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(.title2.weight(.bold))

                    Text(device.status.rawValue)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(device.status.color.opacity(0.15))
                        .foregroundColor(device.status.color)
                        .clipShape(Capsule())
                }

                HStack(spacing: 12) {
                    if let batt = device.batteryPercent {
                        HStack(spacing: 4) {
                            Image(systemName: device.isCharging ? "battery.100bolt" : "battery.100")
                                .foregroundColor(batt < 20 ? .red : (device.isCharging ? .accentColor : .secondary))
                            Text("\(batt)%")
                                .font(.caption.monospacedDigit())
                        }
                        .accessibilityLabel("Battery \(batt) percent\(device.isCharging ? ", charging" : "")")
                    }

                    if let net = device.networkType {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
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
                    Button {
                        device.ping()
                    } label: {
                        Label("Ping", systemImage: "bell.badge")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button {
                        device.findMyPhone()
                    } label: {
                        Label("Ring", systemImage: "speaker.wave.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            } else if device.status == .available {
                Button("Pair Device") {
                    device.pair()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(16)
    }
}

// MARK: - Overview Tab

struct DeviceOverviewTab: View {
    @Bindable var device: DeviceViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Now Playing Card
                if let title = device.nowPlayingTitle, !title.isEmpty {
                    GroupBox("Now Playing on Phone") {
                        HStack(spacing: 14) {
                            Image(systemName: "music.note")
                                .font(.system(size: 28))
                                .foregroundColor(.accentColor)
                                .frame(width: 44, height: 44)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                if let artist = device.nowPlayingArtist, !artist.isEmpty {
                                    Text(artist)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            HStack(spacing: 12) {
                                Button {
                                    device.previousMedia()
                                } label: {
                                    Image(systemName: "backward.fill")
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    device.playPauseMedia()
                                } label: {
                                    Image(systemName: device.nowPlayingIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.title2)
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    device.nextMedia()
                                } label: {
                                    Image(systemName: "forward.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(6)
                    }
                }

                // Volume Control
                if device.status == .connected {
                    GroupBox("Remote Volume") {
                        HStack(spacing: 12) {
                            Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundColor(device.isMuted ? .secondary : .accentColor)
                                .frame(width: 24)

                            Slider(value: Binding(
                                get: { device.volume },
                                set: { device.setVolume($0) }
                            ), in: 0...1)

                            Text("\(Int(device.volume * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .padding(6)
                    }
                }

                // Quick Actions Grid
                GroupBox("Device Actions") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 10) {
                        actionButton(title: "Ping Phone", icon: "bell.badge", disabled: device.status != .connected) {
                            device.ping()
                        }
                        actionButton(title: "Ring Phone", icon: "speaker.wave.3", disabled: device.status != .connected) {
                            device.findMyPhone()
                        }
                        actionButton(title: "Lock Screen", icon: "lock", disabled: device.status != .connected) {
                            device.lockDevice()
                        }
                        actionButton(title: "Push Clipboard", icon: "doc.on.clipboard", disabled: device.status != .connected) {
                            device.sendClipboard()
                        }
                    }
                    .padding(6)
                }

                Spacer()
            }
            .padding(16)
        }
    }

    private func actionButton(title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
    }
}

// MARK: - Notifications Tab

struct DeviceNotificationsTab: View {
    @Bindable var device: DeviceViewModel

    var body: some View {
        if device.notifications.isEmpty {
            ContentUnavailableView(
                "No Notifications",
                systemImage: "bell.slash",
                description: Text("Active notifications received from \(device.name) will appear here.")
            )
        } else {
            List {
                ForEach(device.notifications) { notif in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "app.badge")
                            .font(.title2)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(notif.appName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(notif.date, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Text(notif.title)
                                .font(.body.weight(.medium))

                            Text(notif.body)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            device.dismissNotification(id: notif.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss notification on phone")
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Transfers Tab

struct DeviceTransfersTab: View {
    @Bindable var device: DeviceViewModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            // Drag and drop target / Send button header
            HStack {
                Text("File Sharing")
                    .font(.headline)
                Spacer()
                Button {
                    openSendFileDialog()
                } label: {
                    Label("Send File...", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(16)

            Divider()

            if device.transfers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No Recent Transfers")
                        .font(.title3.weight(.medium))
                    Text("Drag and drop files anywhere here, or click Send File.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
                        .padding(16)
                )
            } else {
                List(device.transfers) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.direction == .incoming ? "arrow.down.doc" : "arrow.up.doc")
                            .font(.title2)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.filename)
                                .font(.body.weight(.medium))
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
                                .font(.caption)
                                .foregroundColor(.secondary)
                        case .cancelled:
                            Text("Cancelled")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
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
}

// MARK: - Remote Input & Presenter Tab

struct DeviceRemoteInputTab: View {
    @Bindable var device: DeviceViewModel
    @State private var isAccessibilityTrusted = InputSynthesizer.shared.isAccessibilityTrusted
    @State private var laserPointerActive = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Remote Mouse, Keyboard & Presentation")
                    .font(.headline)

                Text("Allows \(device.name) to act as a wireless trackpad, keyboard, and laser pointer during slide presentations.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                GroupBox("macOS Accessibility Permissions") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: isAccessibilityTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(isAccessibilityTrusted ? .green : .orange)
                                .font(.title3)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(isAccessibilityTrusted ? "Accessibility Granted" : "Permission Required")
                                    .font(.body.weight(.medium))
                                Text(isAccessibilityTrusted ? "Tether can synthesize cursor movement and clicks." : "Grant permission in System Settings to enable trackpad control.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button("System Settings") {
                                InputSynthesizer.shared.openAccessibilitySettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if !isAccessibilityTrusted {
                            Button("Check / Prompt Permission") {
                                InputSynthesizer.shared.promptAccessibilityPermission()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    isAccessibilityTrusted = InputSynthesizer.shared.isAccessibilityTrusted
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Presenter Overlay") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Virtual Laser Pointer")
                                    .font(.body.weight(.medium))
                                Text("Renders a highlighted pointer dot on your screen during slide presentations.")
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
                    .padding(6)
                }

                Spacer()
            }
            .padding(16)
        }
        .onAppear {
            isAccessibilityTrusted = InputSynthesizer.shared.isAccessibilityTrusted
        }
    }
}

// MARK: - Messages Tab

struct DeviceMessagesTab: View {
    @Bindable var device: DeviceViewModel
    @State private var selectedThreadId: Int64?
    @State private var composeText: String = ""

    var body: some View {
        if device.smsThreads.isEmpty {
            ContentUnavailableView(
                "No Messages",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("SMS threads from \(device.name) will appear here once synchronized.")
            )
        } else {
            NavigationSplitView {
                List(device.smsThreads, selection: $selectedThreadId) { thread in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(thread.title)
                                .font(.body.weight(.medium))
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
                    .padding(.vertical, 2)
                    .tag(thread.id)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
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
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(msg.isOutgoing ? Color.accentColor : Color.secondary.opacity(0.15))
                                            .foregroundColor(msg.isOutgoing ? .white : .primary)
                                            .cornerRadius(14)
                                        if !msg.isOutgoing { Spacer() }
                                    }
                                }
                            }
                            .padding(16)
                        }

                        Divider()

                        HStack {
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

struct DeviceCommandsTab: View {
    @Bindable var device: DeviceViewModel

    var body: some View {
        if device.commands.isEmpty {
            ContentUnavailableView(
                "No Commands Configured",
                systemImage: "terminal",
                description: Text("Shell commands configured in Tether can be triggered remotely from your phone.")
            )
        } else {
            List(device.commands) { cmd in
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.title3)
                        .foregroundColor(.accentColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(cmd.name)
                            .font(.body.weight(.medium))
                        Text(cmd.command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        device.executeCommand(id: cmd.id)
                    } label: {
                        Label("Run on Mac", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - SwiftUI Previews

#Preview("Main Window - Connected Phone (Light)") {
    MainWindowView(appModel: .mock())
        .preferredColorScheme(.light)
}

#Preview("Main Window - Connected Phone (Dark)") {
    MainWindowView(appModel: .mock())
        .preferredColorScheme(.dark)
}

#Preview("Main Window - Empty State") {
    MainWindowView(appModel: .mockEmpty())
}
