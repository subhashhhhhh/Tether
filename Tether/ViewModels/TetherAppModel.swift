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

struct PairRequestViewModel: Identifiable, Sendable {
    let id: String
    let deviceName: String
    let deviceType: DeviceType
    let fingerprint: String?

    init(id: String, deviceName: String, deviceType: DeviceType = .phone, fingerprint: String? = nil) {
        self.id = id
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.fingerprint = fingerprint
    }
}

@Observable
@MainActor
final class TetherAppModel {
    static let shared = TetherAppModel()

    var connectedDevices: [DeviceViewModel] = []
    /// The SMS revision each device view model's threads were last built
    /// from; per view model, since one can be replaced by a fresh one.
    @ObservationIgnored private var smsRevisionSeen: [ObjectIdentifier: Int] = [:]
    var availableDevices: [DeviceViewModel] = []
    var offlineDevices: [DeviceViewModel] = []
    var incomingPairRequest: PairRequestViewModel?
    var selectedDeviceId: String?
    var isShowingConnectByIP = false
    /// Set by the menu bar popover; the main window shows it and clears it.
    var sectionRequest: SectionRequest?
    var isRunning: Bool = false

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var deviceCache: [String: DeviceViewModel] = [:]
    @ObservationIgnored private var isMockMode: Bool = false

    /// Paired devices first (connected, then offline), as shown in the sidebar.
    var pairedDevices: [DeviceViewModel] {
        connectedDevices + offlineDevices
    }

    var allDevices: [DeviceViewModel] {
        connectedDevices + availableDevices + offlineDevices
    }

    var selectedDevice: DeviceViewModel? {
        guard let id = selectedDeviceId else { return nil }
        return allDevices.first { $0.id == id }
    }

    /// The device the menu bar acts on: the selected one if connected, else the first connected.
    var primaryDevice: DeviceViewModel? {
        if let selected = selectedDevice, selected.isConnected { return selected }
        return connectedDevices.first
    }

    /// Notifications and unread texts on connected phones: the Dock badge
    /// and the menu bar icon both show it.
    var waitingCount: Int {
        connectedDevices.reduce(0) { $0 + $1.notifications.count + $1.unreadMessageCount }
    }

    init(isMock: Bool = false) {
        self.isMockMode = isMock
        if !isMock {
            setupLiveSubscriptions()
            rebuildDeviceLists()
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
            service.contactsPlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            service.clipboardPlugin.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        ]
        // objectWillChange fires before the value lands; hop a runloop turn and
        // coalesce bursts (a single SMS sync can publish hundreds of times).
        // A throttle, not a debounce: a steady stream (a transfer's progress)
        // never pauses long enough for a debounce to fire.
        Publishers.MergeMany(pluginChanges)
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
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

    func rebuildDeviceLists() {
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
            if vm.lastSeen != paired.lastSeenDate { vm.lastSeen = paired.lastSeenDate }
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
            // To this device only, and even with clipboard sync off: it was
            // asked for. Broadcasting reached every phone but this one when
            // its sync was off.
            guard let text = NSPasteboard.general.string(forType: .string),
                  let conn = service.connection(for: deviceId) else { return }
            service.clipboardPlugin.send(text, to: conn)
        }
        vm.onCopyReceivedClipboard = { service.clipboardPlugin.copyReceived($0) }
        vm.onCancelTransfer = { service.sharePlugin.cancelTransfer(id: $0) }
        vm.onSendFiles = { urls in service.sendFiles(urls, to: deviceId) }
        vm.onFindPhone = { service.ringPhone(deviceId) }
        vm.onLockDevice = { service.lockPhone(deviceId) }
        let canLock = connection.peerDeviceInfo?.incomingCapabilities.contains(PacketType.lockRequest) ?? false
        if vm.canLock != canLock { vm.canLock = canLock }
        let viaTailscale = TailscaleDiscovery.isTailscaleAddress(connection.host)
        if vm.isViaTailscale != viaTailscale { vm.isViaTailscale = viaTailscale }
        vm.onUnpair = { service.unpair(deviceId: deviceId) }
        vm.onExecuteCommand = { cmdId in
            service.runCommandPlugin.startCommand(key: cmdId, connection: service.connection(for: deviceId))
        }
        vm.onSaveCommand = { command in
            let plugin = service.runCommandPlugin
            if plugin.commands.contains(where: { $0.id == command.id }) {
                plugin.updateCommand(command, connection: service.connection(for: deviceId))
            } else {
                plugin.addCommand(command, connection: service.connection(for: deviceId))
            }
        }
        vm.onDeleteCommand = { cmdId in
            service.runCommandPlugin.removeCommand(id: cmdId, connection: service.connection(for: deviceId))
        }
        vm.onSendSMS = { addresses, text, threadId, subId in
            guard let conn = service.connection(for: deviceId) else { return }
            service.smsPlugin.sendSMS(text: text, to: addresses, threadId: threadId, subId: subId, connection: conn)
        }
        vm.onRefreshMessages = {
            guard let conn = service.connection(for: deviceId) else { return }
            service.smsPlugin.requestAllConversations(connection: conn)
        }
        vm.onOpenAttachment = { attachment in
            service.smsPlugin.openAttachment(attachment, connection: service.connection(for: deviceId))
        }
        vm.onOpenThread = { threadId in
            guard let conn = service.connection(for: deviceId) else { return }
            service.smsPlugin.requestConversation(threadId: threadId, connection: conn)
        }
        vm.onLoadEarlierMessages = { threadId in
            guard let conn = service.connection(for: deviceId) else { return }
            service.smsPlugin.requestEarlierMessages(threadId: threadId, connection: conn)
        }
        vm.onSetVolume = { val in service.setPhoneVolume(Int(val * 100), deviceId: deviceId) }
        vm.onMediaAction = { action in service.mediaAction(action, deviceId: deviceId) }
        vm.onChooseMediaPlayer = { player in
            guard let conn = service.connection(for: deviceId) else { return }
            service.mediaControlPlugin.choosePlayer(player, connection: conn)
        }
        vm.onReplyToNotification = { notification, text in
            service.notificationPlugin.reply(to: notification, text: text)
        }
        vm.onNotificationAction = { notification, action in
            service.notificationPlugin.perform(action, on: notification)
        }
        vm.onDismissNotification = { notification in
            service.notificationPlugin.dismiss(notification)
        }
    }

    private func updateDevicePluginStates() {
        guard !isMockMode else { return }
        let service = TetherService.shared

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
            // Sorted only when texts changed: this runs on every plugin change.
            if smsRevisionSeen[ObjectIdentifier(dev)] != service.smsPlugin.revision {
                smsRevisionSeen[ObjectIdentifier(dev)] = service.smsPlugin.revision
                // Each thread's date is read once, not in every comparison:
                // a phone can have thousands of conversations.
                let threads = (service.smsPlugin.conversations[id] ?? [:]).values
                    .map { (date: $0.lastDate, thread: $0) }
                    .sorted { $0.date > $1.date }
                    .map(\.thread)
                update(dev, \.smsThreads, threads)
                update(dev, \.unreadMessageCount, threads.reduce(0) { $0 + $1.unreadCount })
            }
            update(dev, \.contacts, service.contactsPlugin.books[id] ?? ContactBook())
            update(dev, \.commands, service.runCommandPlugin.commands)
            update(dev, \.notifications, service.notificationPlugin.notifications[id] ?? [])
            update(dev, \.receivedClipboard, service.clipboardPlugin.received[id] ?? [])
            update(dev, \.appGlyphs, service.notificationPlugin.appGlyphs[id] ?? [:])

            let nowPlaying = service.mediaControlPlugin.nowPlaying[id]
            update(dev, \.nowPlayingTitle, nowPlaying?.title)
            update(dev, \.nowPlayingArtist, nowPlaying?.artist)
            update(dev, \.nowPlayingAlbum, nowPlaying?.album)
            update(dev, \.nowPlayingIsPlaying, nowPlaying?.isPlaying ?? false)
            update(dev, \.mediaPlayers, service.mediaControlPlugin.players[id] ?? [])
            update(dev, \.currentMediaPlayer, nowPlaying?.player)
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

    func acceptIncomingPairRequest(_ request: PairRequestViewModel) {
        // The service clears its request when it accepts and the change reaches
        // us; clearing here too would hide a newer request it refused to accept.
        TetherService.shared.acceptIncomingPairRequest(deviceId: request.id, fingerprint: request.fingerprint)
    }

    func rejectIncomingPairRequest() {
        TetherService.shared.rejectIncomingPairRequest()
        incomingPairRequest = nil
    }

    func pair(with deviceId: String) {
        let service = TetherService.shared
        if let info = service.connection(for: deviceId)?.peerDeviceInfo
            ?? service.discoveredDevices.first(where: { $0.deviceId == deviceId }) {
            service.requestPair(with: info)
        }
    }

    func unpair(deviceId: String) {
        TetherService.shared.unpair(deviceId: deviceId)
    }

    func refreshDiscovery(thorough: Bool = true) {
        guard !isMockMode else { return }
        TetherService.shared.refreshDiscovery(thorough: thorough)
        Permissions.shared.refresh()
    }

    /// Adds a device by IPv4 address or host name; false if the name doesn't resolve.
    func addManualPeer(address: String) async -> Bool {
        guard !isMockMode else { return true }
        return await TetherService.shared.addManualPeer(address: address)
    }

}

#if DEBUG
// MARK: - Mocks for Previews

extension TetherAppModel {
    static func mock() -> TetherAppModel {
        let model = TetherAppModel(isMock: true)
        model.isRunning = true
        model.connectedDevices = [.mockConnectedPhone(), .mockConnectedTablet()]
        model.availableDevices = [.mockAvailablePhone()]
        model.offlineDevices = [.mockOfflinePhone()]
        model.selectedDeviceId = "mock_phone"
        return model
    }

    static func mockEmpty() -> TetherAppModel {
        let model = TetherAppModel(isMock: true)
        model.isRunning = true
        return model
    }

    static func mockPairRequest() -> TetherAppModel {
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
