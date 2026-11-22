//
//  PhoneMount.swift
//  Tether
//
//  Mounts a phone as a drive: starts its NFS server on loopback, gives it a
//  local-only Bonjour name (so Finder shows "motorola-edge-50.local" rather
//  than 127.0.0.1), and mounts the share, named after the phone, with
//  mount_nfs. No administrator password is needed for any of it.
//
//  The mount is "soft": if Tether stops answering, file operations fail after
//  a timeout instead of hanging Finder. Tether unmounts when the phone
//  disconnects and when it quits, and cleans up after a crash at launch.
//

import AppKit
import dnssd
import Foundation

nonisolated enum MountError: LocalizedError {
    case mountFailed(String)

    var errorDescription: String? {
        switch self {
        case .mountFailed(let detail): "Couldn't mount the phone: \(detail)"
        }
    }
}

@MainActor
final class PhoneMount {
    let deviceId: String
    let name: String
    let mountPoint: URL
    private let server: PhoneNFSServer
    private var hostName: LocalHostName?

    /// Where phones are mounted. Kept out of the way; Finder lists the drives by name.
    static var mountsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether/Mounts", isDirectory: true)
    }

    init(deviceId: String, name: String, router: PhoneFilesRouter) {
        self.deviceId = deviceId
        // A slash would split the path; macOS shows ":" for "/" in names anyway.
        self.name = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        mountPoint = Self.mountsDirectory.appendingPathComponent(self.name, isDirectory: true)
        server = PhoneNFSServer(name: self.name, deviceId: deviceId, router: router)
    }

    func mount() async throws {
        let port = try await server.start()

        let host = LocalHostName.register(for: name)
        hostName = host
        let serverName = host?.name ?? "localhost"

        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let options = [
            "vers=3", "tcp", "port=\(port)", "mountport=\(port)",
            "soft", "intr", "timeo=100", "retrans=5",       // give up after ~50 s, never hang
            "locallocks", "nonegnamecache",
            "rsize=131072", "wsize=262144", "readahead=1",   // Tether decides how far to read ahead
            "acregmax=10", "acdirmax=10",
        ].joined(separator: ",")
        let result = await Self.run("/sbin/mount_nfs", ["-o", options, "\(serverName):/\(name)", mountPoint.path])
        guard result.status == 0 else {
            await server.stop()
            hostName?.remove()
            hostName = nil
            throw MountError.mountFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        TetherLog("[Files] Mounted \(name) from \(serverName) port \(port)")
    }

    func unmount() async {
        // Off the main thread: a polite unmount waits for the drive to flush,
        // and answering the drive can need the main thread.
        let mountPoint = mountPoint
        _ = await Task.detached { Self.forceUnmount(mountPoint) }.value
        await server.stop()
        hostName?.remove()
        hostName = nil
        Self.removeMountPoint(mountPoint)
        TetherLog("[Files] Unmounted \(name)")
    }

    /// Cleans up after the drive was ejected from outside Tether.
    func stopAfterEject() async {
        await server.stop()
        hostName?.remove()
        hostName = nil
        Self.removeMountPoint(mountPoint)
    }

    /// Unmounts synchronously, for when Tether is quitting.
    func unmountNow() {
        Self.forceUnmount(mountPoint)
        hostName?.remove()
        Self.removeMountPoint(mountPoint)
    }

    // MARK: - Helpers

    /// Unmounts with the system call rather than diskutil, which waits on a
    /// server that's gone. Tries politely first, then forces it (an open file
    /// can't be kept anyway once the phone is gone).
    @discardableResult
    nonisolated static func forceUnmount(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if Darwin.unmount(path, 0) == 0 { return true }
        return Darwin.unmount(path, MNT_FORCE) == 0
    }

    /// Removes an empty mount folder. Never a recursive delete: if the drive
    /// were somehow still mounted, that would delete files on the phone.
    nonisolated static func removeMountPoint(_ url: URL) {
        Darwin.rmdir(url.standardizedFileURL.path)
    }

    static func isMounted(_ url: URL) -> Bool {
        mountedPaths().contains(url.standardizedFileURL.path)
    }

    private static func mountedPaths() -> [String] {
        var count: Int32 = 0
        var pointer: UnsafeMutablePointer<statfs>?
        count = getmntinfo(&pointer, MNT_NOWAIT)
        guard let pointer, count > 0 else { return [] }
        return (0..<Int(count)).map { index in
            withUnsafePointer(to: pointer[index].f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
    }

    /// Unmounts phones left mounted by a previous run that didn't quit cleanly.
    static func cleanUpStaleMounts() {
        // Another copy of Tether (a development build, say) may be serving
        // those drives right now; they're only leftovers when it's alone.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else {
            TetherLog("[Files] Another Tether is running; leaving its phone drives alone")
            return
        }
        let directory = mountsDirectory.standardizedFileURL.path
        for path in mountedPaths() where path.hasPrefix(directory + "/") {
            forceUnmount(URL(fileURLWithPath: path))
            TetherLog("[Files] Unmounted leftover \(path)")
        }
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: directory) {
            for item in leftovers { removeMountPoint(URL(fileURLWithPath: directory + "/" + item)) }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runNow(tool, arguments))
            }
        }
    }

    @discardableResult
    nonisolated private static func runNow(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

/// A Bonjour host name pointing at 127.0.0.1, registered on this Mac only
/// (never announced on the network), so the drive's server has a readable name.
@MainActor
final class LocalHostName {
    let name: String
    private var connection: DNSServiceRef?
    private var record: DNSRecordRef?
    private static var taken = Set<String>()

    private init(name: String) {
        self.name = name
    }

    static func register(for deviceName: String) -> LocalHostName? {
        var base = deviceName.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "phone" }

        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }

        let host = LocalHostName(name: candidate + ".local")
        var connection: DNSServiceRef?
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError, let connection else { return nil }
        var address: [UInt8] = [127, 0, 0, 1]
        var record: DNSRecordRef?
        let status = DNSServiceRegisterRecord(
            connection, &record, DNSServiceFlags(kDNSServiceFlagsShared),
            UInt32(kDNSServiceInterfaceIndexLocalOnly), host.name,
            UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), 4, &address, 120,
            { _, _, _, _, _ in }, nil
        )
        guard status == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(connection)
            return nil
        }
        DNSServiceSetDispatchQueue(connection, .main)
        host.connection = connection
        host.record = record
        taken.insert(candidate)
        return host
    }

    func remove() {
        if let connection {
            DNSServiceRefDeallocate(connection)
            self.connection = nil
        }
        Self.taken.remove(String(name.dropLast(".local".count)))
    }
}
