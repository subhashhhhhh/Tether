//
//  SftpPlugin.swift
//  Tether
//
//  Asks the phone to start KDE Connect's SFTP server and returns how to log
//  in. The phone answers `kdeconnect.sftp.request` (`startBrowsing`) with
//  `kdeconnect.sftp`: its address, port, user, a fresh password, and the
//  storage volumes it shares. It sends `serverRunning` alone when the plugin
//  starts and `errorMessage` when it can't share storage.
//

import Foundation

nonisolated final class SftpPlugin: TetherPlugin, @unchecked Sendable {
    let supportedPacketTypes = [PacketType.sftp]

    struct Credentials: Sendable {
        let address: String
        let port: UInt16
        let user: String
        let password: String
        /// Shared storage volumes: path and display name.
        let volumes: [(path: String, name: String)]
    }

    enum RequestError: LocalizedError {
        case notConnected
        case refused(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notConnected: "The phone isn't connected."
            case .refused(let message): message
            case .timedOut: "The phone didn't start its file server. Check that KDE Connect's Filesystem expose plugin is on."
            }
        }
    }

    private let lock = NSLock()
    private var connections: [String: DeviceConnection] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Credentials, Error>]] = [:]

    init() {}

    func onConnected(connection: DeviceConnection) {
        guard let id = connection.peerDeviceInfo?.deviceId else { return }
        lock.withLock { connections[id] = connection }
    }

    func onDisconnected(connection: DeviceConnection) {
        guard let id = connection.peerDeviceInfo?.deviceId else { return }
        let pending = lock.withLock { () -> [CheckedContinuation<Credentials, Error>] in
            guard connections[id] === connection else { return [] }
            connections.removeValue(forKey: id)
            return Array((waiters.removeValue(forKey: id) ?? [:]).values)
        }
        pending.forEach { $0.resume(throwing: RequestError.notConnected) }
    }

    func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == PacketType.sftp, let id = connection.peerDeviceInfo?.deviceId else { return }

        let result: Result<Credentials, Error>
        if let message = packet.string(for: "errorMessage") {
            result = .failure(RequestError.refused(message))
        } else if let password = packet.string(for: "password"), let user = packet.string(for: "user") {
            let port = UInt16(clamping: packet.int(for: "port"))
            let paths = (packet.body["multiPaths"]?.value as? [Any])?.compactMap { $0 as? String }
                ?? [packet.string(for: "path") ?? "/"]
            let names = (packet.body["pathNames"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
            let volumes = paths.enumerated().map { index, path in
                (path: path, name: index < names.count ? names[index] : (path as NSString).lastPathComponent)
            }
            // Connect to the address this connection uses: the one the phone
            // reports may be on a network the Mac can't reach (e.g. over Tailscale).
            result = .success(Credentials(address: connection.host, port: port, user: user,
                                          password: password, volumes: volumes))
        } else {
            return // `serverRunning` status
        }

        let pending = lock.withLock { Array((waiters.removeValue(forKey: id) ?? [:]).values) }
        pending.forEach { $0.resume(with: result) }
    }

    /// Starts the phone's SFTP server and returns fresh login details.
    func requestCredentials(deviceId: String) async throws -> Credentials {
        guard let connection = lock.withLock({ connections[deviceId] }) else { throw RequestError.notConnected }
        let token = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let first = lock.withLock { () -> Bool in
                defer { waiters[deviceId, default: [:]][token] = continuation }
                return waiters[deviceId]?.isEmpty ?? true
            }
            if first {
                connection.send(packet: NetworkPacket(type: PacketType.sftpRequest, body: ["startBrowsing": true]))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self else { return }
                lock.withLock { self.waiters[deviceId]?.removeValue(forKey: token) }?
                    .resume(throwing: RequestError.timedOut)
            }
        }
    }
}
