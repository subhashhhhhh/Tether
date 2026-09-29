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
    public var searchText: String = ""
    public var isRunning: Bool = false
    public var isSearching: Bool = false
    public var notificationAuthStatus: UNAuthorizationStatus = .authorized

    public var isNotificationPermissionDenied: Bool {
        notificationAuthStatus == .denied
    }

    private var cancellables = Set<AnyCancellable>()
    private var isMockMode: Bool = false

    public var filteredConnectedDevices: [DeviceViewModel] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return connectedDevices
        }
        return connectedDevices.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    public var filteredAvailableDevices: [DeviceViewModel] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return availableDevices
        }
        return availableDevices.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    public var filteredOfflineDevices: [DeviceViewModel] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return offlineDevices
        }
        return offlineDevices.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    public var allDevices: [DeviceViewModel] {
        connectedDevices + availableDevices + offlineDevices
    }

    public var selectedDevice: DeviceViewModel? {
        guard let id = selectedDeviceId else { return connectedDevices.first }
        return allDevices.first { $0.id == id }
    }

    public var statusIconName: String {
        if !connectedDevices.isEmpty {
            return "iphone.badge.checkmark"
        } else if isRunning {
            return "antenna.radiowaves.left.and.right"
        } else {
            return "antenna.radiowaves.left.and.right.slash"
        }
    }

    public var statusSubtitle: String {
        if !connectedDevices.isEmpty {
            let names = connectedDevices.map(\.name).joined(separator: ", ")
            return "Connected to \(names)"
        } else if isRunning {
            return "Searching for devices..."
        } else {
            return "Tether Offline"
        }
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
        let trustStore = TrustStore.shared

        service.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.isRunning = running
            }
            .store(in: &cancellables)

        service.$connectedDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildDeviceLists()
            }
            .store(in: &cancellables)

        service.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildDeviceLists()
            }
            .store(in: &cancellables)

        service.$incomingPairRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pairReq in
                if let req = pairReq {
                    self?.incomingPairRequest = PairRequestViewModel(
                        id: req.info.deviceId,
                        deviceName: req.info.deviceName,
                        deviceType: req.info.deviceType,
                        fingerprint: req.connection.peerCertificateFingerprint
                    )
                } else {
                    self?.incomingPairRequest = nil
                }
            }
            .store(in: &cancellables)

        trustStore.$pairedDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildDeviceLists()
            }
            .store(in: &cancellables)

        // Plugin updates
        service.batteryPlugin.$deviceBatteries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDevicePluginStates()
            }
            .store(in: &cancellables)

        service.connectivityReportPlugin.$signalStrength
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDevicePluginStates()
            }
            .store(in: &cancellables)

        service.sharePlugin.$transfers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDevicePluginStates()
            }
            .store(in: &cancellables)

        service.smsPlugin.$conversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDevicePluginStates()
            }
            .store(in: &cancellables)

        service.runCommandPlugin.$commands
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDevicePluginStates()
            }
            .store(in: &cancellables)

        service.mediaControlPlugin.$nowPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDevicePluginStates()
            }
            .store(in: &cancellables)

        service.remoteVolumePlugin.$sinks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDevicePluginStates()
            }
            .store(in: &cancellables)
    }

    public func rebuildDeviceLists() {
        guard !isMockMode else { return }
        let service = TetherService.shared
        let trustStore = TrustStore.shared

        var connected: [DeviceViewModel] = []
        var available: [DeviceViewModel] = []
        var offline: [DeviceViewModel] = []

        let pairedIds = Set(trustStore.pairedDevices.keys)
        var connectedIds = Set<String>()

        // 1. Process active connections
        for (deviceId, conn) in service.connectedDevices {
            guard !conn.isDisconnected else { continue }
            connectedIds.insert(deviceId)

            let name = conn.peerDeviceInfo?.deviceName ?? trustStore.pairedDevice(for: deviceId)?.deviceName ?? "Device"
            let type = conn.peerDeviceInfo?.deviceType ?? trustStore.pairedDevice(for: deviceId)?.deviceType ?? .phone

            let vm = DeviceViewModel(
                id: deviceId,
                name: name,
                deviceType: type,
                status: .connected
            )
            wireActions(to: vm, connection: conn)
            connected.append(vm)
        }

        // 2. Process discovered un-paired devices
        for disc in service.discoveredDevices {
            if !pairedIds.contains(disc.deviceId) && !connectedIds.contains(disc.deviceId) {
                let vm = DeviceViewModel(
                    id: disc.deviceId,
                    name: disc.deviceName,
                    deviceType: disc.deviceType,
                    status: .available
                )
                let discId = disc.deviceId
                vm.onPair = { [weak self] in
                    self?.pair(with: discId)
                }
                available.append(vm)
            }
        }

        // 3. Process offline paired devices
        for (pairedId, paired) in trustStore.pairedDevices {
            if !connectedIds.contains(pairedId) {
                let vm = DeviceViewModel(
                    id: pairedId,
                    name: paired.deviceName,
                    deviceType: paired.deviceType,
                    status: .offline
                )
                let devId = pairedId
                vm.onUnpair = { [weak self] in
                    self?.unpair(deviceId: devId)
                }
                offline.append(vm)
            }
        }

        self.connectedDevices = connected
        self.availableDevices = available
        self.offlineDevices = offline

        updateDevicePluginStates()

        if selectedDeviceId == nil || !allDevices.contains(where: { $0.id == selectedDeviceId }) {
            selectedDeviceId = connected.first?.id ?? offline.first?.id
        }
    }

    private func wireActions(to vm: DeviceViewModel, connection: DeviceConnection) {
        let deviceId = vm.id
        let service = TetherService.shared

        vm.onPing = { [weak service] in
            service?.sendPing(to: deviceId)
        }
        vm.onSendClipboard = { [weak service] in
            if let text = NSPasteboard.general.string(forType: .string) {
                service?.clipboardPlugin.broadcastClipboard(content: text)
            }
        }
        vm.onSendFile = { [weak service] url in
            service?.sendFiles([url], to: deviceId)
        }
        vm.onFindPhone = { [weak service] in
            service?.ringPhone(deviceId)
        }
        vm.onLockDevice = { [weak service] in
            service?.lockPhone(deviceId)
        }
        vm.onUnpair = { [weak service] in
            service?.unpair(deviceId: deviceId)
        }
        vm.onExecuteCommand = { [weak service] cmdId in
            if let conn = service?.connectedDevices[deviceId] {
                service?.runCommandPlugin.startCommand(key: cmdId, connection: conn)
            }
        }
        vm.onSendSMS = { [weak service] addr, text in
            service?.smsPlugin.sendSMS(text: text, to: [addr], connection: connection)
        }
        vm.onSetVolume = { [weak service] val in
            service?.setPhoneVolume(Int(val * 100), deviceId: deviceId)
        }
        vm.onMediaAction = { [weak service] action in
            service?.mediaAction(action, deviceId: deviceId)
        }
    }

    private func updateDevicePluginStates() {
        guard !isMockMode else { return }
        let service = TetherService.shared

        for dev in connectedDevices {
            let id = dev.id
            if let battery = service.batteryPlugin.deviceBatteries[id] {
                dev.batteryPercent = battery.currentCharge
                dev.isCharging = battery.isCharging
            }
            if let signal = service.connectivityReportPlugin.signalStrength[id] {
                dev.networkType = signal.networkType
                dev.cellularSignalStrength = signal.strength
            }
            dev.transfers = service.sharePlugin.transfers.filter { $0.deviceId == id }
            dev.smsThreads = Array(service.smsPlugin.conversations.values).sorted(by: { $0.id > $1.id })
            dev.commands = service.runCommandPlugin.commands

            if let np = service.mediaControlPlugin.nowPlaying[id] {
                dev.nowPlayingTitle = np.title
                dev.nowPlayingArtist = np.artist
                dev.nowPlayingIsPlaying = np.isPlaying
            }
            if let sink = service.remoteVolumePlugin.sinks[id]?.first {
                dev.volume = Float(sink.fraction)
                dev.isMuted = sink.muted
            }
        }
    }

    // Actions
    public func acceptIncomingPairRequest() {
        TetherService.shared.acceptIncomingPairRequest()
        incomingPairRequest = nil
    }

    public func rejectIncomingPairRequest() {
        TetherService.shared.rejectIncomingPairRequest()
        incomingPairRequest = nil
    }

    public func pair(with deviceId: String) {
        if let dev = TetherService.shared.discoveredDevices.first(where: { $0.deviceId == deviceId }) {
            TetherService.shared.requestPair(with: dev)
        }
    }

    public func unpair(deviceId: String) {
        TetherService.shared.unpair(deviceId: deviceId)
    }

    public func refreshDiscovery() {
        TetherService.shared.refreshDiscovery()
        checkNotificationStatus()
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Mocks for Previews

    public static func mock() -> TetherAppModel {
        let model = TetherAppModel(isMock: true)
        model.isRunning = true
        model.connectedDevices = [
            DeviceViewModel.mockConnectedPhone(),
            DeviceViewModel.mockConnectedTablet()
        ]
        model.availableDevices = [
            DeviceViewModel.mockAvailablePhone()
        ]
        model.offlineDevices = [
            DeviceViewModel.mockOfflinePhone()
        ]
        model.selectedDeviceId = "mock_phone"
        return model
    }

    public static func mockEmpty() -> TetherAppModel {
        let model = TetherAppModel(isMock: true)
        model.isRunning = true
        model.connectedDevices = []
        model.availableDevices = []
        model.offlineDevices = []
        model.selectedDeviceId = nil
        return model
    }

    public static func mockPairRequest() -> TetherAppModel {
        let model = TetherAppModel.mock()
        model.incomingPairRequest = PairRequestViewModel(
            id: "pair_req_dev",
            deviceName: "Pixel 9 Pro",
            deviceType: .phone,
            fingerprint: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
        )
        return model
    }
}
