//
//  PhoneFileTransport.swift
//  Tether
//
//  How Tether reaches a phone's storage for Finder: SFTP through KDE Connect
//  (the default, works on any network including Tailscale), or ADB through
//  wireless debugging (opt-in, for people who already use it).
//
//  Paths are the phone's absolute paths. `PhoneFiles.rootPath` stands for the
//  top level Finder shows: the one storage volume, or a folder per volume.
//

import Foundation

protocol PhoneFileTransport: Actor {
    func list(_ path: String) async throws -> [RemoteFile]
    func info(_ path: String) async throws -> RemoteFile
    /// Writes the file into `fileDescriptor`, from offset 0.
    func download(_ path: String, to fileDescriptor: Int32) async throws
    /// Up to `length` bytes at `offset`; fewer only at the end of the file.
    func read(_ path: String, offset: Int64, length: Int) async throws -> Data
    func upload(from fileDescriptor: Int32, size: Int64, folder: String, name: String, modified: Date?) async throws -> RemoteFile
    func makeDirectory(folder: String, name: String) async throws -> RemoteFile
    func delete(_ path: String, isDirectory: Bool) async throws
    func move(_ path: String, toFolder folder: String, name: String) async throws -> RemoteFile
    func close() async
}

nonisolated enum PhoneFileError: LocalizedError {
    case notConnected(String)
    case rootIsVirtual

    var errorDescription: String? {
        switch self {
        case .notConnected(let reason): reason
        case .rootIsVirtual: "Choose a storage location on the phone first."
        }
    }
}

nonisolated func joinPath(_ folder: String, _ name: String) -> String {
    folder.hasSuffix("/") ? folder + name : folder + "/" + name
}

// MARK: - SFTP

/// KDE Connect's SFTP server. Login details come from the phone over the
/// paired, encrypted KDE Connect connection, and are fetched again whenever
/// the session drops. The server's host key is pinned on first use.
actor SFTPTransport: PhoneFileTransport {
    private let deviceId: String
    private let plugin: SftpPlugin
    private var client: SFTPClient?
    private var connecting: Task<SFTPClient, Error>?
    private var volumes: [(path: String, name: String)] = []

    init(deviceId: String, plugin: SftpPlugin) {
        self.deviceId = deviceId
        self.plugin = plugin
    }

    static func hostKeyDefaultsKey(_ deviceId: String) -> String { "tether_files_hostkey_\(deviceId)" }

    private func session() async throws -> SFTPClient {
        if let client, !(await client.isClosed) { return client }
        if let connecting { return try await connecting.value }

        let plugin = plugin, deviceId = deviceId
        let task = Task { () throws -> (SFTPClient, [(path: String, name: String)]) in
            let credentials = try await plugin.requestCredentials(deviceId: deviceId)
            let pinKey = Self.hostKeyDefaultsKey(deviceId)
            let client = try await SFTPClient.connect(
                host: credentials.address, port: credentials.port,
                user: credentials.user, password: credentials.password,
                checkHostKey: { key in
                    let defaults = UserDefaults.standard
                    if let pinned = defaults.string(forKey: pinKey) {
                        if pinned != key.fingerprint {
                            TetherLog("[Files] SFTP host key changed: expected \(pinned), got \(key.fingerprint)")
                        }
                        return pinned == key.fingerprint
                    }
                    defaults.set(key.fingerprint, forKey: pinKey)
                    return true
                }
            )
            return (client, credentials.volumes)
        }
        let waiting = Task { try await task.value.0 }
        connecting = waiting
        defer { connecting = nil }
        let (session, sessionVolumes) = try await task.value
        volumes = sessionVolumes
        client = session
        TetherLog("[Files] SFTP session open (\(volumes.count) storage volume(s))")
        return session
    }

    /// Runs an operation, reconnecting once if the session had dropped.
    private func perform<T: Sendable>(_ operation: (SFTPClient) async throws -> T) async throws -> T {
        do {
            return try await operation(try await session())
        } catch let error as SFTPError {
            throw error
        } catch SSHError.hostKeyMismatch {
            throw SSHError.hostKeyMismatch
        } catch {
            await client?.close()
            client = nil
            openFiles.removeAll()
            return try await operation(try await session())
        }
    }

    private func resolve(_ folder: String) async throws -> String {
        guard folder == PhoneFiles.rootPath else { return folder }
        if volumes.isEmpty { _ = try await session() }
        guard volumes.count == 1 else { throw PhoneFileError.rootIsVirtual }
        return volumes[0].path
    }

    func list(_ path: String) async throws -> [RemoteFile] {
        if path == PhoneFiles.rootPath {
            _ = try await session()
            if volumes.count != 1 {
                return volumes.map { RemoteFile(path: $0.path, name: $0.name, isDirectory: true, size: 0, modified: nil) }
            }
        }
        let folder = try await resolve(path)
        return try await perform { try await $0.list(folder) }
    }

    func info(_ path: String) async throws -> RemoteFile {
        if path == PhoneFiles.rootPath {
            return RemoteFile(path: path, name: "", isDirectory: true, size: 0, modified: nil)
        }
        var file = try await perform { try await $0.stat(path) }
        if let volume = volumes.first(where: { $0.path == path }) { file.name = volume.name }
        return file
    }

    func download(_ path: String, to fileDescriptor: Int32) async throws {
        _ = try await perform { try await $0.download(path, to: fileDescriptor) { _ in } }
    }

    /// Files kept open for reads, so a video can be read piece by piece.
    private var openFiles: [String: (handle: Data, used: Date)] = [:]

    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        try await perform { client in
            let handle: Data
            if let open = openFiles[path] {
                handle = open.handle
            } else {
                handle = try await client.openForReading(path)
                if openFiles.count >= 12, let oldest = openFiles.min(by: { $0.value.used < $1.value.used }) {
                    openFiles.removeValue(forKey: oldest.key)
                    await client.closeFile(oldest.value.handle)
                }
            }
            openFiles[path] = (handle, Date())
            return try await client.read(handle, offset: offset, length: length)
        }
    }

    /// Forgets open handles for a path that changed, so reads see the new contents.
    func invalidate(_ path: String) async {
        guard let open = openFiles.removeValue(forKey: path) else { return }
        await client?.closeFile(open.handle)
    }

    func upload(from fileDescriptor: Int32, size: Int64, folder: String, name: String, modified: Date?) async throws -> RemoteFile {
        let path = joinPath(try await resolve(folder), name)
        await invalidate(path)
        try await perform { try await $0.upload(from: fileDescriptor, size: size, to: path, modified: modified) { _ in } }
        return try await info(path)
    }

    func makeDirectory(folder: String, name: String) async throws -> RemoteFile {
        let path = joinPath(try await resolve(folder), name)
        try await perform { try await $0.makeDirectory(path) }
        return try await info(path)
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        await invalidate(path)
        if isDirectory {
            try await perform { try await $0.removeRecursively(path) }
        } else {
            try await perform { try await $0.removeFile(path) }
        }
    }

    func move(_ path: String, toFolder folder: String, name: String) async throws -> RemoteFile {
        let destination = joinPath(try await resolve(folder), name)
        await invalidate(path)
        await invalidate(destination)
        try await perform { try await $0.rename(path, to: destination) }
        return try await info(destination)
    }

    func close() async {
        await client?.close()
        client = nil
        openFiles.removeAll()
    }
}
