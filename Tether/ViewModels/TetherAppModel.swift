//
//  TetherAppModel.swift
//  Tether
//
//  Root @Observable view model providing unified application state to SwiftUI surfaces.
//

import SwiftUI
import Observation
import Combine
import AppKit
import UserNotifications

public struct PairRequestViewModel: Identifiable, Sendable {
    public let id: String
    public let deviceName: String
    public let deviceType: DeviceType
    public let fingerprint: String?

    public init(id: String, deviceName: String, deviceType: DeviceType = .phone, fingerprint: String? = nil) {
        self.id = id
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.fingerprint = fingerprint
    }
}

@Observable
@MainActor
public final class TetherAppModel {
    public static let shared = TetherAppModel()

    public var connectedDevices: [DeviceViewModel] = []
    public var availableDevices: [DeviceViewModel] = []
    public var offlineDevices: [DeviceViewModel] = []
    public var incomingPairRequest: PairRequestViewModel?
    public var selectedDeviceId: String?
    public var isShowingConnectByIP = false
    public var isRunning: Bool = false
    public var notificationAuthStatus: UNAuthorizationStatus = .authorized

    public var isNotificationPermissionDenied: Bool {
        notificationAuthStatus == .denied
    }

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var deviceCache: [String: DeviceViewModel] = [:]
    @ObservationIgnored private var isMockMode: Bool = false

    /// Paired devices first (connected, then offline), as shown in the sidebar.
    public var pairedDevices: [DeviceViewModel] {
        connectedDevices + offlineDevices
    }

    public var allDevices: [DeviceViewModel] {
        connectedDevices + availableDevices + offlineDevices
    }

    public var selectedDevice: DeviceViewModel? {
        guard let id = selectedDeviceId else { return nil }
        return allDevices.first { $0.id == id }
    }

    /// The device the menu bar acts on: the selected one if connected, else the first connected.
    public var primaryDevice: DeviceViewModel? {
        if let selected = selectedDevice, selected.isConnected { return selected }
        return connectedDevices.first
    }

    public var statusMenuBarImageName: String {
        connectedDevices.isEmpty ? "MenuBarDisconnected" : "MenuBarConnected"
    }

    public init(isMock: Bool = false) {
        self.isMockMode = isMock
        if !isMock {
            setupLiveSubscriptions()
            rebuildDeviceLists()
            checkNotificationStatus()
        }
    }

    private func setupLiveSubscriptions() {
        let service = TetherService.shared

        service.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in self?.isRunning = running }
            .store(in: &cancellables)

        service.$incomingPairRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                self?.incomingPairRequest = request.map {
                    PairRequestViewModel(
                        id: $0.info.deviceId,
                        deviceName: $0.info.deviceName,
                        deviceType: $0.info.deviceType,
                        fingerprint: $0.connection.peerCertificateFingerprint
                    )
                }
            }
            .store(in: &cancellables)

        let deviceListChanges: [AnyPublisher<Void, Never>] = [
            service.$connectedDevices.map { _ in () }.eraseToAnyPublisher(),
            service.$discoveredDevices.map { _ in () }.eraseToAnyPublisher(),
            TrustStore.shared.$pairedDevices.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(deviceListChanges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rebuildDeviceLists() }
            .store(in: &cancellables)

        let pluginChanges: [AnyPublisher<Void, Never>] = [
            service.batteryPlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.connectivityReportPlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.sharePlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.smsPlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.runCommandPlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.mediaControlPlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.remoteVolumePlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.notificationPlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.contactsPlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        ]
        // objectWillChange fires before the value lands; hop a runloop turn and
        // coalesce bursts (a single SMS sync can publish hundreds of times).
        Publishers.MergeMany(pluginChanges)
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.updateDevicePluginStates() }
            .store(in: &cancellables)
    }

    /// Returns the cached view model for `id`, creating it once.
    private func device(id: String, name: String, type: DeviceType, status: DeviceStatus) -> DeviceViewModel {
        let vm = deviceCache[id] ?? DeviceViewModel(id: id, name: name, deviceType: type, status: status)
        deviceCache[id] = vm
        if vm.name != name { vm.name = name }
        if vm.deviceType != type { vm.deviceType = type }
        if vm.status != status {
            vm.status = status
            vm.isAwaitingPairing = false
        }
        return vm
    }

    public func rebuildDeviceLists() {
        guard !isMockMode else { return }
        let service = TetherService.shared
        let trustStore = TrustStore.shared

        var connected: [DeviceViewModel] = []
        var available: [DeviceViewModel] = []
        var offline: [DeviceViewModel] = []
        var connectedIds = Set<String>()

        // A connection only counts once its certificate has been verified.
        for (deviceId, conn) in service.connectedDevices where !conn.isDisconnected && conn.pairState == .paired {
            connectedIds.insert(deviceId)
            let paired = trustStore.pairedDevice(for: deviceId)
            let vm = device(
                id: deviceId,
                name: conn.peerDeviceInfo?.deviceName ?? paired?.deviceName ?? "Device",
                type: conn.peerDeviceInfo?.deviceType ?? paired?.deviceType ?? .phone,
                status: .connected
            )
            wireConnectedActions(to: vm, connection: conn)
            connected.append(vm)
        }

        // Connected but not verified: never paired, or presenting a different
        // certificate than the pinned one (e.g. KDE Connect was reinstalled).
        // Either way the fix is to pair, so these show as nearby, not offline.
        let unverifiedIds = Set(service.connectedDevices.compactMap { id, conn in
            !conn.isDisconnected && conn.pairState != .paired ? id : nil
        })

        for (pairedId, paired) in trustStore.pairedDevices where !connectedIds.contains(pairedId) && !unverifiedIds.contains(pairedId) {
            let vm = device(id: pairedId, name: paired.deviceName, type: paired.deviceType, status: .offline)
            vm.lastSeen = paired.lastSeenDate
            vm.onUnpair = { [weak self] in self?.unpair(deviceId: pairedId) }
            offline.append(vm)
        }

        // Nearby, unpaired: anything heard through discovery, plus devices that
        // connected straight in without broadcasting first (common over
        // Tailscale or when the phone was given this Mac's address).
        var nearby: [String: DeviceInfo] = [:]
        for disc in service.discoveredDevices { nearby[disc.deviceId] = disc }
        for (deviceId, conn) in service.connectedDevices where !conn.isDisconnected && conn.pairState != .paired {
            if let info = conn.peerDeviceInfo { nearby[deviceId] = info }
        }
        let knownIds = connectedIds.union(Set(trustStore.pairedDevices.keys).subtracting(unverifiedIds))
        for info in nearby.values where !knownIds.contains(info.deviceId) {
            let vm = device(id: info.deviceId, name: info.deviceName, type: info.deviceType, status: .available)
            let nearbyId = info.deviceId
            vm.onPair = { [weak self] in self?.pair(with: nearbyId) }
            available.append(vm)
        }

        let byName: (DeviceViewModel, DeviceViewModel) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        connectedDevices = connected.sorted(by: byName)
        availableDevices = available.sorted(by: byName)
        offlineDevices = offline.sorted(by: byName)

        updateDevicePluginStates()
        ShareInbox.shared.publishConnectedDevices(connectedDevices)
        PhoneFilesController.shared.update(
            paired: trustStore.pairedDevices.mapValues(\.deviceName),
            connected: connectedIds
        )

        if selectedDeviceId == nil || !allDevices.contains(where: { $0.id == selectedDeviceId }) {
            selectedDeviceId = connectedDevices.first?.id ?? offlineDevices.first?.id ?? availableDevices.first?.id
        }
    }

    private func wireConnectedActions(to vm: DeviceViewModel, connection: DeviceConnection) {
        let deviceId = vm.id
        let service = TetherService.shared

        vm.onPing = { service.sendPing(to: deviceId) }
        vm.onSendClipboard = {
            if let text = NSPasteboard.general.string(forType: .string) {
                service.clipboardPlugin.broadcastClipboard(content: text)
            }
        }
        vm.onSendFiles = { urls in service.sendFiles(urls, to: deviceId) }
        vm.onFindPhone = { service.ringPhone(deviceId) }
        vm.onLockDevice = { service.lockPhone(deviceId) }
        let canLock = connection.peerDeviceInfo?.incomingCapabilities.contains("kdeconnect.lock.request") ?? false
        if vm.canLock != canLock { vm.canLock = canLock }
        // Tailscale addresses are in 100.64.0.0/10.
        let octets = connection.host.split(separator: ".").compactMap { Int($0) }
        let viaTailscale = octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
        if vm.isViaTailscale != viaTailscale { vm.isViaTailscale = viaTailscale }
        vm.onUnpair = { service.unpair(deviceId: deviceId) }
        vm.onExecuteCommand = { cmdId in
            service.runCommandPlugin.startCommand(key: cmdId, connection: service.connectedDevices[deviceId])
        }
        vm.onSaveCommand = { command in
            let plugin = service.runCommandPlugin
            if plugin.commands.contains(where: { $0.id == command.id }) {
                plugin.updateCommand(command, connection: service.connectedDevices[deviceId])
            } else {
                plugin.addCommand(command, connection: service.connectedDevices[deviceId])
            }
        }
        vm.onDeleteCommand = { cmdId in
            service.runCommandPlugin.removeCommand(id: cmdId, connection: service.connectedDevices[deviceId])
        }
        vm.onSendSMS = { addresses, text, threadId, subId in
            guard let conn = service.connectedDevices[deviceId] else { return }
            service.smsPlugin.sendSMS(text: text, to: addresses, threadId: threadId, subId: subId, connection: conn)
        }
        vm.onRefreshMessages = {
            guard let conn = service.connectedDevices[deviceId] else { return }
            service.smsPlugin.requestAllConversations(connection: conn)
        }
        vm.onOpenThread = { threadId in
            guard let conn = service.connectedDevices[deviceId] else { return }
            service.smsPlugin.requestConversation(threadId: threadId, connection: conn)
        }
        vm.onLoadEarlierMessages = { threadId in
            guard let conn = service.connectedDevices[deviceId] else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                service.smsPlugin.requestEarlierMessages(threadId: threadId, connection: conn)
            }
        }
        vm.onSetVolume = { val in service.setPhoneVolume(Int(val * 100), deviceId: deviceId) }
        vm.onMediaAction = { action in service.mediaAction(action, deviceId: deviceId) }
        vm.onReplyToNotification = { notification, text in
            service.notificationPlugin.reply(to: notification, text: text)
        }
        vm.onDismissNotification = { notification in
            service.notificationPlugin.dismiss(notification)
        }
    }

    private func updateDevicePluginStates() {
        guard !isMockMode else { return }
        let service = TetherService.shared
        let threads = service.smsPlugin.conversations.values.sorted { $0.lastDate > $1.lastDate }

        for dev in connectedDevices {
            let id = dev.id
            // Assign only on change: this runs after every plugin update (a busy
            // SMS sync publishes hundreds of times) and each write re-renders.
            if let battery = service.batteryPlugin.deviceBatteries[id] {
                update(dev, \.batteryPercent, battery.currentCharge)
                update(dev, \.isCharging, battery.isCharging)
            }
            if let signal = service.connectivityReportPlugin.signalStrength[id] {
                update(dev, \.networkType, signal.networkType)
                update(dev, \.cellularSignalStrength, signal.strength)
            }
            let sims = (service.connectivityReportPlugin.subscriptions[id] ?? [:])
                .sorted { $0.key < $1.key }
                .enumerated()
                .map { PhoneSIM(id: $1.key, number: $0 + 1, networkType: $1.value.shortLabel) }
            update(dev, \.sims, sims)
            update(dev, \.transfers, service.sharePlugin.transfers.filter { $0.deviceId == id })
            update(dev, \.smsThreads, threads)
            update(dev, \.contacts, service.contactsPlugin.books[id] ?? ContactBook())
            update(dev, \.commands, service.runCommandPlugin.commands)
            update(dev, \.notifications, service.notificationPlugin.notifications[id] ?? [])

            let nowPlaying = service.mediaControlPlugin.nowPlaying[id]
            update(dev, \.nowPlayingTitle, nowPlaying?.title)
            update(dev, \.nowPlayingArtist, nowPlaying?.artist)
            update(dev, \.nowPlayingAlbum, nowPlaying?.album)
            update(dev, \.nowPlayingIsPlaying, nowPlaying?.isPlaying ?? false)
            dev.setAlbumArt(service.mediaControlPlugin.albumArt[id])

            // Same order as TetherService.setPhoneVolume: the media player's
            // volume on a phone, a sink's on a desktop.
            let hasPlayer = !(service.mediaControlPlugin.players[id] ?? []).isEmpty
            let sinks = service.remoteVolumePlugin.sinks[id]
            if hasPlayer, let nowPlaying {
                update(dev, \.volume, Float(nowPlaying.volume) / 100)
                update(dev, \.isMuted, false)
            } else if let sink = sinks?.first(where: { $0.enabled }) ?? sinks?.first {
                update(dev, \.volume, Float(sink.fraction))
                update(dev, \.isMuted, sink.muted)
            }
            update(dev, \.canSetVolume, hasPlayer || !(sinks ?? []).isEmpty)
        }
    }

    private func update<Value: Equatable>(_ device: DeviceViewModel, _ keyPath: ReferenceWritableKeyPath<DeviceViewModel, Value>, _ value: Value) {
        if device[keyPath: keyPath] != value { device[keyPath: keyPath] = value }
    }

    // MARK: - Actions

    public func acceptIncomingPairRequest(_ request: PairRequestViewModel) {
        TetherService.shared.acceptIncomingPairRequest(deviceId: request.id, fingerprint: request.fingerprint)
        incomingPairRequest = nil
    }

    public func rejectIncomingPairRequest() {
        TetherService.shared.rejectIncomingPairRequest()
        incomingPairRequest = nil
    }

    public func pair(with deviceId: String) {
        let service = TetherService.shared
        if let info = service.connectedDevices[deviceId]?.peerDeviceInfo
            ?? service.discoveredDevices.first(where: { $0.deviceId == deviceId }) {
            service.requestPair(with: info)
        }
    }

    public func unpair(deviceId: String) {
        TetherService.shared.unpair(deviceId: deviceId)
    }

    public func refreshDiscovery(thorough: Bool = true) {
        guard !isMockMode else { return }
        TetherService.shared.refreshDiscovery(thorough: thorough)
        checkNotificationStatus()
    }

    /// Adds a device by IPv4 address or host name; false if the name doesn't resolve.
    public func addManualPeer(address: String) async -> Bool {
        guard !isMockMode else { return true }
        return await TetherService.shared.addManualPeer(address: address)
    }

    public func checkNotificationStatus() {
        guard !isMockMode else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationAuthStatus = settings.authorizationStatus
            }
        }
    }

    public func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

#if DEBUG
// MARK: - Mocks for Previews

extension TetherAppModel {
    public static func mock() -> TetherAppModel {
        let model = TetherAppModel(isMock: true)
        model.isRunning = true
        model.connectedDevices = [.mockConnectedPhone(), .mockConnectedTablet()]
        model.availableDevices = [.mockAvailablePhone()]
        model.offlineDevices = [.mockOfflinePhone()]
        model.selectedDeviceId = "mock_phone"
        return model
    }

    public static func mockEmpty() -> TetherAppModel {
        let model = TetherAppModel(isMock: true)
        model.isRunning = true
        return model
    }

    public static func mockPairRequest() -> TetherAppModel {
        let model = TetherAppModel.mock()
        model.incomingPairRequest = PairRequestViewModel(
            id: "pair_req_dev",
            deviceName: "Nothing Phone (2)",
            deviceType: .phone,
            fingerprint: "a4:1f:9c:22:7e:d0:4b:88:13:6a:f2:e5:90:3c:7d:01:bb:48:c6:5e:09:d7:21:f3:6e:84:a0:55:cd:12:9b:3f"
        )
        return model
    }
}
#endif
