//
//  MainWindowView.swift
//  Tether
//
//  The main window: each device's sections in a sidebar, as Mail lists an
//  account's mailboxes, and the selected section on the right.
//

import SwiftUI
import AppKit

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

/// What the sidebar can select: a section of a connected device, or a device
/// that has no sections to show (offline, or nearby and unpaired).
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

extension EnvironmentValues {
    /// True while the window's sidebar is hidden, when its toolbar buttons
    /// sit over the detail area's top-leading corner.
    @Entry var isSidebarCollapsed = false
}

/// A request, from the menu bar popover, to show a device's section.
struct SectionRequest: Equatable {
    let deviceId: String
    let section: DeviceSection
}

struct MainWindowView: View {
    @Bindable var appModel: TetherAppModel
    @State private var selection: SidebarItem?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    init(appModel: TetherAppModel) {
        self.init(appModel: appModel, initialSection: .overview)
    }

    init(appModel: TetherAppModel, initialSection: DeviceSection) {
        self.appModel = appModel
        _selection = State(initialValue: appModel.selectedDeviceId.map { SidebarItem(deviceId: $0, section: initialSection) })
    }

    /// Phone notifications and unread texts, across connected devices.
    private var dockBadgeCount: Int {
        appModel.connectedDevices.reduce(0) { total, device in
            total + device.notifications.count + device.unreadMessageCount
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DeviceSidebar(appModel: appModel, selection: $selection) {
                appModel.isShowingConnectByIP = true
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
                .environment(\.isSidebarCollapsed, columnVisibility == .detailOnly)
                .toolbar {
                    // Page actions sit at the trailing edge whether or not
                    // anything else is in the toolbar.
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 520)
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
        .onAppear {
            applySectionRequest()
            DockPresence.windowOpened()
        }
        .onDisappear { DockPresence.windowClosed() }
        .onChange(of: dockBadgeCount, initial: true) { DockPresence.setBadge(dockBadgeCount) }
        .onChange(of: appModel.sectionRequest) { applySectionRequest() }
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
        .onChange(of: appModel.connectedDevices.map(\.id)) {
            // A device that drops loses its section rows; fall back to the device.
            if case .section(let id, _) = selection, !appModel.connectedDevices.contains(where: { $0.id == id }) {
                selection = .device(id)
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            // Without it no phone can be found or reached. The first-run page
            // says so itself.
            if Permissions.shared.localNetwork == .off, !appModel.allDevices.isEmpty {
                PermissionBanner(
                    systemImage: "network.slash",
                    message: "Local Network access is off for Tether, so it can't find or reach your phone on Wi-Fi.",
                    action: Permissions.shared.openLocalNetworkSettings
                )
            }
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selection, let device = appModel.allDevices.first(where: { $0.id == selection.deviceId }) {
            DeviceDetailView(
                device: device,
                appModel: appModel,
                section: device.isConnected ? selection.section : .overview,
                onSelectSection: { self.selection = SidebarItem(deviceId: device.id, section: $0) },
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

    private func applySectionRequest() {
        guard let request = appModel.sectionRequest else { return }
        selection = SidebarItem(deviceId: request.deviceId, section: request.section)
        appModel.sectionRequest = nil
    }

    /// The sheet can only be closed by answering it, which clears the request in the model.
    private var pairRequestBinding: Binding<PairRequestViewModel?> {
        Binding(get: { appModel.incomingPairRequest }, set: { _ in })
    }
}

// MARK: - Sidebar

/// An outline, as Mail lists accounts and Finder lists disks: each device is
/// a row that shows its overview, with its sections folded under it. A device
/// that isn't in use can be folded away, and still shows what's waiting.
struct DeviceSidebar: View {
    let appModel: TetherAppModel
    @Binding var selection: SidebarItem?
    let onConnectByIP: () -> Void

    @State private var deviceToUnpair: DeviceViewModel?
    /// IDs of the devices the user has folded, comma-separated.
    @AppStorage("tether_folded_devices") private var foldedDevices = ""

    /// The sections under a device. Its own row is the overview.
    private static let childSections = DeviceSection.allCases.filter { $0 != .overview }

    var body: some View {
        List(selection: $selection) {
            if !appModel.pairedDevices.isEmpty {
                Section("My Devices") {
                    ForEach(appModel.pairedDevices) { device in
                        if device.isConnected {
                            DisclosureGroup(isExpanded: isExpanded(device.id)) {
                                ForEach(Self.childSections) { section in
                                    Label(section.title, systemImage: section.systemImage)
                                        .badge(badgeCount(for: section, device: device))
                                        .tag(SidebarItem.section(device.id, section))
                                }
                            } label: {
                                DeviceLabel(device: device, pending: isFolded(device.id) ? pendingCount(for: device) : 0)
                            }
                            .tag(SidebarItem.device(device.id))
                            .contextMenu { contextMenu(for: device) }
                        } else {
                            DeviceLabel(device: device, pending: 0)
                                .tag(SidebarItem.device(device.id))
                                .contextMenu { contextMenu(for: device) }
                        }
                    }
                }
            }

            // Discovery runs in the background; the section appears once
            // an unpaired device has been found.
            if !appModel.availableDevices.isEmpty {
                Section("Nearby") {
                    ForEach(appModel.availableDevices) { device in
                        Label(device.name, systemImage: device.deviceType.systemImageName)
                            .badge(Text(device.isAwaitingPairing ? "Waiting…" : ""))
                            .tag(SidebarItem.device(device.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button("Connect by Address…", systemImage: "plus", action: onConnectByIP)
                    .help("Connect to a device by its address")
            }
        }
        .onChange(of: selection) {
            // Going to a section (Show All on the overview, say) opens its
            // device, so the selected row is never hidden.
            if case .section(let id, _) = selection, isFolded(id) { setFolded(false, id) }
        }
        .unpairConfirmation(for: $deviceToUnpair, name: \.name) { $0.unpair() }
    }

    // MARK: Folding

    private var foldedIds: Set<String> {
        Set(foldedDevices.split(separator: ",").map(String.init))
    }

    private func isFolded(_ id: String) -> Bool { foldedIds.contains(id) }

    private func setFolded(_ folded: Bool, _ id: String) {
        var ids = foldedIds
        if folded { ids.insert(id) } else { ids.remove(id) }
        foldedDevices = ids.sorted().joined(separator: ",")
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !isFolded(id) }, set: { setFolded(!$0, id) })
    }

    // MARK: Counts

    /// What's waiting in a section: unread texts, notifications, files on the move.
    private func badgeCount(for section: DeviceSection, device: DeviceViewModel) -> Int {
        switch section {
        case .notifications: device.notifications.count
        case .messages: device.unreadMessageCount
        case .files: device.activeTransferCount
        case .overview, .commands: 0
        }
    }

    /// Everything waiting on a device, for its row while it's folded.
    private func pendingCount(for device: DeviceViewModel) -> Int {
        Self.childSections.reduce(0) { $0 + badgeCount(for: $1, device: device) }
    }

    @ViewBuilder
    private func contextMenu(for device: DeviceViewModel) -> some View {
        if device.isConnected {
            ForEach([DeviceAction.findPhone, .sendFiles], id: \.self) { action in
                Button(action.menuTitle(for: device), systemImage: action.systemImage) { action.perform(on: device) }
            }
            Divider()
        }
        Button("Unpair…", systemImage: "link.badge.minus", role: .destructive) { deviceToUnpair = device }
    }
}

/// A device's row: its name, then how it's doing in a quieter voice on the
/// same line. One line keeps the disclosure arrow and the icon level with
/// the text, and a Label lets the sidebar colour the icon, white on a
/// selected row included. At the trailing edge, what's waiting while folded.
private struct DeviceLabel: View {
    let device: DeviceViewModel
    let pending: Int

    var body: some View {
        Label {
            // Centred, not on a shared baseline: the smaller text would sit
            // below the middle of the row.
            HStack(alignment: .center, spacing: 6) {
                Text(device.name)
                    .lineLimit(1)
                    .layoutPriority(1)
                // Pushed to the row's trailing edge, where a sidebar keeps
                // its counts, so names line up and status reads as a column.
                Spacer(minLength: 4)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            if device.isConnected {
                Image(systemName: device.deviceType.systemImageName)
            } else {
                Image(systemName: device.deviceType.systemImageName)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(device.isConnected ? .primary : .secondary)
        .badge(pending)
        .help(detail)
        .accessibilityLabel("\(device.name), \(detail)")
    }

    /// "Wi-Fi · 27% · LTE", or when it was last seen.
    private var detail: String {
        guard device.isConnected else { return device.statusLine }
        var parts = [device.isViaTailscale ? "Tailscale" : "Wi-Fi"]
        if let battery = device.batteryPercent { parts.append("\(battery)%") }
        if let network = device.networkType, !network.isEmpty, !parts.contains(network) { parts.append(network) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Menu commands

