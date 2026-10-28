//
//  MainWindowView.swift
//  Tether
//
//  The main window: devices in a sidebar, and the selected device on the
//  right, with its sections as tabs in the toolbar.
//

import SwiftUI

enum DeviceSection: String, CaseIterable, Identifiable {
    case overview, messages, notifications, files, commands

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .messages: "Messages"
        case .notifications: "Notifications"
        case .files: "Files"
        case .commands: "Commands"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "iphone.gen3"
        case .messages: "message"
        case .notifications: "bell"
        case .files: "folder"
        case .commands: "terminal"
        }
    }
}

/// What the sidebar can select. Selecting a device shows its overview.
enum SidebarItem: Hashable {
    case device(String)
    case section(String, DeviceSection)

    var deviceId: String {
        switch self {
        case .device(let id), .section(let id, _): id
        }
    }

    var section: DeviceSection {
        switch self {
        case .device: .overview
        case .section(_, let section): section
        }
    }

    init(deviceId: String, section: DeviceSection) {
        self = section == .overview ? .device(deviceId) : .section(deviceId, section)
    }
}

public struct MainWindowView: View {
    @Bindable var appModel: TetherAppModel
    @State private var selection: SidebarItem?
    @State private var section: DeviceSection

    public init(appModel: TetherAppModel) {
        self.init(appModel: appModel, initialSection: .overview)
    }

    init(appModel: TetherAppModel, initialSection: DeviceSection) {
        self.appModel = appModel
        _selection = State(initialValue: appModel.selectedDeviceId.map(SidebarItem.device))
        _section = State(initialValue: initialSection)
    }

    public var body: some View {
        NavigationSplitView {
            DeviceSidebar(appModel: appModel, selection: $selection) {
                appModel.isShowingConnectByIP = true
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $appModel.isShowingConnectByIP) {
            ConnectByIPSheet { await appModel.addManualPeer(address: $0) }
        }
        .sheet(item: pairRequestBinding) { request in
            PairRequestSheet(
                request: request,
                onAccept: { appModel.acceptIncomingPairRequest(request) },
                onDecline: { appModel.rejectIncomingPairRequest() }
            )
        }
        .onAppear { appModel.checkNotificationStatus() }
        .onChange(of: selection) {
            if let id = selection?.deviceId, id != appModel.selectedDeviceId {
                appModel.selectedDeviceId = id
            }
        }
        .onChange(of: appModel.selectedDeviceId) {
            // The model may pick a device itself (first launch, menu bar, unpair).
            if selection?.deviceId != appModel.selectedDeviceId {
                selection = appModel.selectedDeviceId.map(SidebarItem.device)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let device = appModel.allDevices.first(where: { $0.id == selection.deviceId }) {
            DeviceDetailView(
                device: device,
                appModel: appModel,
                section: device.isConnected ? section : .overview,
                onSelectSection: { section = $0 },
                onConnectByIP: { appModel.isShowingConnectByIP = true }
            )
        } else if appModel.allDevices.isEmpty {
            OnboardingView(appModel: appModel) {
                appModel.isShowingConnectByIP = true
            }
        } else {
            ContentUnavailableView("No Device Selected", systemImage: "iphone.gen3", description: Text("Choose a device in the sidebar."))
        }
    }

    /// The sheet can only be closed by answering it, which clears the request in the model.
    private var pairRequestBinding: Binding<PairRequestViewModel?> {
        Binding(get: { appModel.incomingPairRequest }, set: { _ in })
    }
}

// MARK: - Sidebar

struct DeviceSidebar: View {
    let appModel: TetherAppModel
    @Binding var selection: SidebarItem?
    let onConnectByIP: () -> Void

    @State private var deviceToUnpair: DeviceViewModel?

    private var pairedRows: [SidebarRow] {
        appModel.pairedDevices.map { SidebarRow(item: .device($0.id), device: $0) }
    }

    var body: some View {
        List(selection: $selection) {
            if !appModel.pairedDevices.isEmpty {
                Section("My Devices") {
                    ForEach(pairedRows) { row in
                        SidebarRowView(row: row)
                            .tag(row.item)
                            .contextMenu { contextMenu(for: row.device) }
                    }
                }
            }

            // Discovery runs in the background; the section appears once
            // an unpaired device has been found.
            if !appModel.availableDevices.isEmpty {
                Section("Nearby") {
                    ForEach(appModel.availableDevices) { device in
                        SidebarRowView(row: SidebarRow(item: .device(device.id), device: device))
                            .tag(SidebarItem.device(device.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onConnectByIP) {
                Label("Connect by Address…", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .confirmationDialog(
            "Unpair \(deviceToUnpair?.name ?? "device")?",
            isPresented: Binding(get: { deviceToUnpair != nil }, set: { if !$0 { deviceToUnpair = nil } }),
            presenting: deviceToUnpair
        ) { device in
            Button("Unpair", role: .destructive) { device.unpair() }
        } message: { device in
            Text("You'll need to pair again from \(device.name) to reconnect.")
        }
    }

    @ViewBuilder
    private func contextMenu(for device: DeviceViewModel) -> some View {
        if device.isConnected {
            Button("Find Phone", systemImage: "speaker.wave.3") { device.findMyPhone() }
            Button("Send Files…", systemImage: "square.and.arrow.up") {
                device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name))
            }
            Divider()
        }
        Button("Unpair…", systemImage: "link.badge.minus", role: .destructive) { deviceToUnpair = device }
    }
}

struct SidebarRow: Identifiable {
    let item: SidebarItem
    let device: DeviceViewModel
    var id: SidebarItem { item }
}

private struct SidebarRowView: View {
    let row: SidebarRow

    var body: some View {
        switch row.item {
        case .device:
            DeviceRow(device: row.device)
        case .section(_, let section):
            Label(section.title, systemImage: section.systemImage)
                .padding(.leading, 18)
                .badge(badgeCount(for: section))
        }
    }

    private func badgeCount(for section: DeviceSection) -> Int {
        switch section {
        case .notifications: row.device.notifications.count
        case .messages: row.device.smsThreads.reduce(0) { $0 + $1.unreadCount }
        case .files: row.device.activeTransferCount
        case .overview, .commands: 0
        }
    }
}

struct DeviceRow: View {
    let device: DeviceViewModel
    var body: some View {
        // A Label lets the sidebar size the icon from the user's
        // "Sidebar icon size" setting, like every other sidebar on the Mac.
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .lineLimit(1)
                Text(device.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            // Connected devices keep the sidebar's own icon colouring (accent,
            // white when selected); only devices out of reach are dimmed.
            if device.isConnected {
                Image(systemName: device.deviceType.systemImageName)
            } else {
                Image(systemName: device.deviceType.systemImageName)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Menu commands

struct TetherCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let appModel: TetherAppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tether") { TetherCredits.showAboutPanel() }
            Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
        }

        CommandGroup(after: .newItem) {
            Button("Connect by Address…") {
                openWindow(id: "main")
                appModel.isShowingConnectByIP = true
            }
            .keyboardShortcut("k")

            Button("Look for Devices") { appModel.refreshDiscovery() }
                .keyboardShortcut("r")
        }

        CommandMenu("Device") {
            let device = appModel.primaryDevice
            Button("Send Files…") {
                if let device { device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name)) }
            }
            .keyboardShortcut("o")
            .disabled(device == nil)

            Button("Send Clipboard") { device?.sendClipboard() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(device == nil)

            Divider()

            Button("Find Phone") { device?.findMyPhone() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(device == nil)

            if device?.canLock == true {
                Button("Lock") { device?.lockDevice() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            Button("Ping") { device?.ping() }
                .disabled(device == nil)
        }
    }
}
