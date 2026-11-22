//
//  ADBTransport.swift
//  Tether
//
//  Phone storage over ADB, using the phone's wireless debugging and the `adb`
//  tool installed on the Mac (Android SDK or `brew install android-platform-tools`).
//  It's opt-in and meant for people who already use ADB: they enter the
//  address and port shown under Developer options › Wireless debugging.
//
//  ADB gives full access to the phone, so this only runs file commands
//  (find, stat, cat, mkdir, rm, mv) on paths Finder asked for, each quoted.
//

import Foundation

nonisolated enum ADBError: LocalizedError {
    case notInstalled
    case unreachable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "adb isn't installed. Install it with: brew install android-platform-tools"
        case .unreachable(let detail): "Couldn't reach the phone over wireless debugging. \(detail)"
        case .failed(let detail): detail
        }
    }
}

actor ADBTransport: PhoneFileTransport {
    /// Internal storage, which is what ADB shares here.
    static let storagePath = "/storage/emulated/0"
    static let storageName = "Internal shared storage"

    static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
    }()

    static var executable: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    let address: String
    private var isConnected = false

    init(address: String) {
        self.address = address
    }

    // MARK: - Running adb

    private struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    private func run(_ arguments: [String], stdin: FileHandle? = nil, stdout: FileHandle? = nil) async throws -> Output {
        guard let adb = Self.executable else { throw ADBError.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = stdout ?? outPipe
        process.standardError = errPipe
        process.standardInput = stdin ?? FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            // Read both pipes while it runs, so a large listing can't fill a pipe and stall adb.
            let group = DispatchGroup()
            // Read on two threads; the group orders the reads before the result.
            let collected = Collected()
            group.enter()
            DispatchQueue.global().async {
                if stdout == nil { collected.set(out: outPipe.fileHandleForReading.readDataToEndOfFile()) }
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                collected.set(err: errPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            process.terminationHandler = { process in
                group.notify(queue: .global()) {
                    let (out, err) = collected.values
                    continuation.resume(returning: Output(status: process.terminationStatus, stdout: out,
                                                          stderr: String(decoding: err, as: UTF8.self)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ADBError.failed("Couldn't run adb: \(error.localizedDescription)"))
            }
        }
    }

    private func ensureConnected() async throws {
        if isConnected {
            let state = try await run(["-s", address, "get-state"])
            if state.status == 0 { return }
            isConnected = false
        }
        let result = try await run(["connect", address])
        let text = String(decoding: result.stdout, as: UTF8.self) + result.stderr
        guard text.contains("connected to") else {
            throw ADBError.unreachable(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        isConnected = true
    }

    /// Runs a shell command on the phone and returns its output.
    private func shell(_ command: String, stdin: FileHandle? = nil, stdout: FileHandle? = nil) async throws -> Data {
        try await ensureConnected()
        let verb = stdin != nil ? "exec-in" : (stdout != nil ? "exec-out" : "shell")
        let result = try await run(["-s", address, verb, command], stdin: stdin, stdout: stdout)
        // `shell` reports the command's exit status; exec-in/exec-out don't, so
        // for those an error message on stderr is the only sign of failure.
        let failedQuietly = verb != "shell" && (result.stderr.contains("No such file") || result.stderr.contains("Permission denied"))
        if result.status != 0 || failedQuietly {
            let output = (stdout == nil ? String(decoding: result.stdout, as: UTF8.self) : "") + result.stderr
            if output.contains("No such file") { throw SFTPError.noSuchFile }
            if output.contains("Permission denied") { throw SFTPError.permissionDenied }
            if output.contains("offline") || output.contains("not found") || output.contains("closed") {
                isConnected = false
                throw ADBError.unreachable(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw ADBError.failed(output.isEmpty ? "adb exited with status \(result.status)" : output)
        }
        return result.stdout
    }

    /// Single-quotes a path for the phone's shell.
    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func resolve(_ folder: String) -> String {
        folder == PhoneFiles.rootPath ? storagePath : folder
    }

    /// Parses `stat -c '%s|%Y|%f|%n'` lines: size, modified, raw mode (hex), path.
    private static func parse(_ output: Data) -> [RemoteFile] {
        String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let size = Int64(fields[0]), let seconds = TimeInterval(fields[1]),
                  let mode = UInt32(fields[2], radix: 16) else { return nil }
            let path = String(fields[3])
            return RemoteFile(path: path, name: (path as NSString).lastPathComponent,
                              isDirectory: mode & 0o170000 == 0o040000, size: size,
                              modified: Date(timeIntervalSince1970: seconds))
        }
    }

    private static let statFormat = "'%s|%Y|%f|%n'"

    // MARK: - PhoneFileTransport

    func list(_ path: String) async throws -> [RemoteFile] {
        let folder = Self.resolve(path)
        let output = try await shell("find \(Self.quote(folder)) -mindepth 1 -maxdepth 1 -exec stat -c \(Self.statFormat) {} + 2>/dev/null; true")
        return Self.parse(output)
    }

    func info(_ path: String) async throws -> RemoteFile {
        if path == PhoneFiles.rootPath {
            return RemoteFile(path: path, name: Self.storageName, isDirectory: true, size: 0, modified: nil)
        }
        guard let file = Self.parse(try await shell("stat -c \(Self.statFormat) \(Self.quote(path))")).first else {
            throw SFTPError.noSuchFile
        }
        return file
    }

    func download(_ path: String, to fileDescriptor: Int32) async throws {
        let expected = try await info(path).size
        let sink = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        _ = try await shell("cat \(Self.quote(path))", stdout: sink)
        let written = lseek(fileDescriptor, 0, SEEK_END)
        guard written == expected else {
            throw ADBError.failed("The download from the phone stopped early.")
        }
    }

    // MARK: Reads

    /// A file being streamed from the phone into a local cache file. ADB can't
    /// read from an arbitrary position cheaply, so a read waits until the
    /// stream has passed it.
    private final class Stream: @unchecked Sendable {
        let url: URL
        let size: Int64
        var finished = false
        var failure: Error?
        var used = Date()

        init(url: URL, size: Int64) {
            self.url = url
            self.size = size
        }

        var available: Int64 {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
    }

    private var streams: [String: Stream] = [:]

    private static var cacheDirectory: URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TetherADBReads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        let stream = try await stream(for: path)
        stream.used = Date()
        let end = min(offset + Int64(length), stream.size)
        guard offset < end else { return Data() }

        let deadline = Date().addingTimeInterval(120)
        while stream.available < end, !stream.finished {
            if Date() > deadline { throw ADBError.failed("Reading from the phone timed out.") }
            try await Task.sleep(for: .milliseconds(30))
        }
        if let failure = stream.failure { throw failure }

        let handle = try FileHandle(forReadingFrom: stream.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: Int(end - offset)) ?? Data()
    }

    private func stream(for path: String) async throws -> Stream {
        if let stream = streams[path], stream.failure == nil { return stream }

        let size = try await info(path).size
        let url = Self.cacheDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let stream = Stream(url: url, size: size)

        // Keep a few files; delete the least recently read.
        if streams.count >= 6, let oldest = streams.min(by: { $0.value.used < $1.value.used }) {
            streams.removeValue(forKey: oldest.key)
            try? FileManager.default.removeItem(at: oldest.value.url)
        }
        streams[path] = stream

        let sink = try FileHandle(forWritingTo: url)
        Task {
            do {
                _ = try await self.shell("cat \(Self.quote(path))", stdout: sink)
            } catch {
                stream.failure = error
            }
            try? sink.close()
            stream.finished = true
        }
        return stream
    }

    /// Drops the cached copy of a path that changed.
    private func invalidate(_ path: String) {
        if let stream = streams.removeValue(forKey: path) {
            try? FileManager.default.removeItem(at: stream.url)
        }
    }

    func upload(from fileDescriptor: Int32, size: Int64, folder: String, name: String, modified: Date?) async throws -> RemoteFile {
        let path = joinPath(Self.resolve(folder), name)
        invalidate(path)
        lseek(fileDescriptor, 0, SEEK_SET)
        let source = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        _ = try await shell("cat > \(Self.quote(path))", stdin: source)
        let file = try await info(path)
        guard file.size == size else { throw ADBError.failed("The upload to the phone stopped early.") }
        return file
    }

    func makeDirectory(folder: String, name: String) async throws -> RemoteFile {
        let path = joinPath(Self.resolve(folder), name)
        _ = try await shell("mkdir \(Self.quote(path))")
        return try await info(path)
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        invalidate(path)
        _ = try await shell((isDirectory ? "rm -rf " : "rm -f ") + Self.quote(path))
    }

    func move(_ path: String, toFolder folder: String, name: String) async throws -> RemoteFile {
        let destination = joinPath(Self.resolve(folder), name)
        invalidate(path)
        invalidate(destination)
        _ = try await shell("mv \(Self.quote(path)) \(Self.quote(destination))")
        return try await info(destination)
    }

    func close() async {}
}

/// A command's output, read on two threads.
private nonisolated final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func set(out data: Data) { lock.withLock { out = data } }
    func set(err data: Data) { lock.withLock { err = data } }
    var values: (Data, Data) { lock.withLock { (out, err) } }
}
