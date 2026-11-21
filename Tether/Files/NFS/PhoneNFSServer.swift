//
//  PhoneNFSServer.swift
//  Tether
//
//  An NFS version 3 server (RFC 1813, plus the MOUNT protocol) on the Mac's
//  loopback interface, backed by the phone's storage through SFTP or ADB.
//  macOS mounts it as a drive named after the phone; see PhoneMount.
//
//  - Reads fetch only what's asked for, in 512 KB chunks with read-ahead, so
//    videos start playing while the rest is still on the phone.
//  - Writes collect in a local file and go to the phone in one upload when
//    the Mac commits the file (on close), or after a few idle seconds.
//  - macOS's own metadata files ("._*" and .DS_Store) stay on the Mac.
//

import Foundation

private nonisolated enum NFSStatus: UInt32 {
    case ok = 0
    case noEntry = 2
    case io = 5
    case access = 13
    case exists = 17
    case notDirectory = 20
    case isDirectory = 21
    case invalid = 22
    case nameTooLong = 63
    case notEmpty = 66
    case stale = 70
    case badHandle = 10001
    case notSupported = 10004
    case serverFault = 10006
}

private nonisolated struct NFSFailure: Error {
    let status: NFSStatus
}

actor PhoneNFSServer {
    private static let nfsProgram: UInt32 = 100003
    private static let mountProgram: UInt32 = 100005
    /// Reads fetch 128 KB at a time, so peeking at a file (as Finder does
    /// for previews) costs little; reading in order grows the read-ahead.
    private static let chunkSize = 128 * 1024
    private static let maxReadAhead = 16          // chunks, i.e. 2 MB
    private static let maxPrefetches = 4
    /// A listing younger than this is used as is; older but usable ones are
    /// served immediately while a fresh copy loads in the background.
    private static let listingFresh: TimeInterval = 5
    private static let listingUsable: TimeInterval = 120

    let exportPath: String
    private let router: PhoneFilesRouter
    private let rpc: RPCServer
    private let fsid: UInt64
    private let session: UInt64 = .random(in: 1...UInt64.max)
    private let writeVerifier: UInt64 = .random(in: 1...UInt64.max)
    private let uid = getuid(), gid = getgid()

    // File handles: a random session number plus a per-path number.
    private var paths: [UInt64: String] = [1: PhoneFiles.rootPath]
    private var ids: [String: UInt64] = [PhoneFiles.rootPath: 1]

    private var listings: [String: (files: [RemoteFile], fetched: Date)] = [:]
    /// What the root lists, and, with one storage volume, that volume's real
    /// path (the root shows its contents).
    private var rootEntries = Set<String>()
    private var volumeRoot: String?
    private var attributes: [String: RemoteFile] = [:]
    private var chunks = ChunkCache(limit: 128 * 1024 * 1024)
    private var chunkLoads: [String: Task<Data, Error>] = [:]
    private var listingLoads: [String: Task<[RemoteFile], Error>] = [:]
    /// Per file: where the last read ended and how far ahead to fetch.
    private var readPattern: [String: (end: Int64, window: Int)] = [:]
    private var prefetching = 0
    /// Fetches from the phone run at most four at a time, so previews being
    /// generated for a whole folder can't crowd out what you actually opened.
    private static let maxFetches = 4
    private var activeFetches = 0
    private var waitingFetches: [CheckedContinuation<Void, Never>] = []
    private var stats = Stats()

    private struct Stats {
        var reads = 0, servedBytes = 0, fetchedBytes = 0, listings = 0, files = Set<String>()
        var isEmpty: Bool { reads == 0 && listings == 0 }
    }

    /// Files being written, held on the Mac until uploaded.
    private final class Staged {
        var url: URL
        let descriptor: Int32
        /// Finder's own files, kept on the Mac across mounts.
        var persistent = false
        var size: Int64 = 0
        var modified = Date()
        var dirty = true
        /// Counts writes, so an upload knows whether what it sent is still
        /// the latest. Size alone misses a write that overwrites in place.
        var generation = 0
        var lastWrite = Date()
        var upload: Task<Void, Error>?

        init(url: URL, descriptor: Int32) {
            self.url = url
            self.descriptor = descriptor
        }

        deinit {
            close(descriptor)
            if !persistent { try? FileManager.default.removeItem(at: url) }
        }
    }
    private var staged: [String: Staged] = [:]
    private let stagingDirectory: URL
    /// Where Finder's .DS_Store and "._" files for this phone are kept, mirroring
    /// the phone's folders, so view settings (such as turning off previews) stick.
    private let metadataDirectory: URL

    init(name: String, deviceId: String, router: PhoneFilesRouter) {
        exportPath = "/" + name
        self.router = router
        fsid = Self.stableHash(deviceId)
        stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TetherNFS-\(deviceId)", isDirectory: true)
        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        metadataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether/Finder Metadata/\(deviceId)", isDirectory: true)

        let owner = WeakServer()
        rpc = RPCServer { call in
            guard let server = owner.server else { return .programUnavailable }
            return await server.handle(call)
        }
        owner.server = self
    }

    func start() async throws -> UInt16 {
        let port = try await rpc.start()
        Task { [weak self] in
            while let self, await self.logActivity() {
                try? await Task.sleep(for: .seconds(10), tolerance: .seconds(5))
            }
        }
        return port
    }

    /// Logs what Finder asked for in the last 10 seconds. Returns false once stopped.
    private func logActivity() -> Bool {
        if !stats.isEmpty {
            TetherLog("[NFS] 10 s: \(stats.reads) reads of \(stats.files.count) file(s), served \(stats.servedBytes / 1024) KB, fetched \(stats.fetchedBytes / 1024) KB from the phone, \(stats.listings) listing(s)")
            stats = Stats()
        }
        return !stopped
    }

    private var stopped = false

    func stop() {
        stopped = true
        rpc.stop()
        staged.removeAll()
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    // MARK: - Dispatch

    private func handle(_ call: RPCCall) async -> RPCResult {
        var args = XDRReader(call.arguments)
        do {
            switch (call.program, call.version) {
            case (Self.mountProgram, 3):
                return .success(try mount(call.procedure, &args))
            case (Self.nfsProgram, 3):
                return .success(try await nfs(call.procedure, &args))
            case (Self.mountProgram, _), (Self.nfsProgram, _):
                return .programUnavailable
            default:
                return .programUnavailable
            }
        } catch is XDRError {
            return .garbageArguments
        } catch {
            return .procedureUnavailable
        }
    }

    private func mount(_ procedure: UInt32, _ args: inout XDRReader) throws -> Data {
        var reply = XDRWriter()
        switch procedure {
        case 0: break // NULL
        case 1: // MNT
            let path = try args.string()
            guard path == exportPath || path == "/" else {
                reply.uint32(2) // MNT3ERR_NOENT
                return reply.data
            }
            reply.uint32(0)
            reply.opaque(handle(for: PhoneFiles.rootPath))
            reply.uint32(1)
            reply.uint32(1) // AUTH_UNIX
        case 3: break // UMNT
        default: break
        }
        return reply.data
    }

    // MARK: - Handles and attributes

    /// File IDs are derived from the path, so they're the same every time the
    /// phone is mounted: macOS can then reuse the previews it already made.
    private func handle(for path: String) -> Data {
        let id: UInt64
        if let existing = ids[path] {
            id = existing
        } else {
            var candidate = max(2, Self.stableHash(path))
            while let taken = paths[candidate], taken != path { candidate &+= 1 }
            id = candidate
            ids[path] = id
            paths[id] = path
        }
        var writer = XDRWriter()
        writer.uint64(session)
        writer.uint64(id)
        return writer.data
    }

    private func path(from handle: Data) throws -> String {
        guard handle.count == 16 else { throw NFSFailure(status: .badHandle) }
        var reader = XDRReader(handle)
        guard try reader.uint64() == session, let path = paths[try reader.uint64()] else {
            throw NFSFailure(status: .stale)
        }
        return path
    }

    private func readHandle(_ args: inout XDRReader) throws -> String {
        try path(from: try args.opaque(maxLength: 64))
    }

    private func renameHandle(from old: String, to new: String) {
        let prefix = old + "/"
        for (id, path) in paths where path == old || path.hasPrefix(prefix) {
            let moved = new + path.dropFirst(old.count)
            paths[id] = moved
            ids.removeValue(forKey: path)
            ids[moved] = id
        }
    }

    /// FNV-1a: stable across launches, unlike Swift's hashValue.
    nonisolated static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return hash
    }

    private static func isMacMetadata(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store"
    }

    /// The folder a path appears in, in the drive's terms (the root is "").
    private func parent(of path: String) -> String {
        if path == PhoneFiles.rootPath || rootEntries.contains(path) { return PhoneFiles.rootPath }
        let parent = (path as NSString).deletingLastPathComponent
        return parent == volumeRoot ? PhoneFiles.rootPath : parent
    }

    private func listing(_ folder: String, fresh: Bool = false) async throws -> [RemoteFile] {
        if !fresh, let cached = listings[folder] {
            let age = Date().timeIntervalSince(cached.fetched)
            if age < Self.listingUsable {
                if age >= Self.listingFresh { _ = loadListing(folder) } // refresh in the background
                return merged(cached.files, in: folder)
            }
        }
        let files: [RemoteFile]
        do {
            files = try await loadListing(folder).value
        } catch {
            throw Self.failure(for: error)
        }
        store(files, in: folder)
        return merged(files, in: folder)
    }

    /// Lists a folder on the phone, sharing one request between everyone asking.
    private func loadListing(_ folder: String) -> Task<[RemoteFile], Error> {
        if let loading = listingLoads[folder] { return loading }
        stats.listings += 1
        let router = router
        let task = Task { try await router.run { try await $0.list(folder) } }
        listingLoads[folder] = task
        Task {
            if let files = try? await task.value { store(files, in: folder) }
            listingLoads[folder] = nil
        }
        return task
    }

    private func store(_ files: [RemoteFile], in folder: String) {
        listings[folder] = (files, Date())
        if folder == PhoneFiles.rootPath {
            rootEntries = Set(files.map(\.path))
            let parents = Set(files.map { ($0.path as NSString).deletingLastPathComponent })
            volumeRoot = parents.count == 1 ? parents.first : nil
        }
        for file in files { attributes[file.path] = file }
    }

    private func metadataURL(for path: String) -> URL {
        metadataDirectory.appendingPathComponent(String(path.drop { $0 == "/" }))
    }

    /// Opens Finder's saved files for a folder, so they're served like staged ones.
    private func loadSavedMetadata(in folder: String) {
        let real = folder == PhoneFiles.rootPath ? volumeRoot : folder
        guard let real, let names = try? FileManager.default.contentsOfDirectory(atPath: metadataURL(for: real).path) else { return }
        for name in names where Self.isMacMetadata(name) {
            let path = joinPath(real, name)
            guard staged[path] == nil else { continue }
            let url = metadataURL(for: path)
            let descriptor = open(url.path, O_RDWR)
            guard descriptor >= 0 else { continue }
            let file = Staged(url: url, descriptor: descriptor)
            file.persistent = true
            file.dirty = false
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            file.size = (attributes?[.size] as? Int64) ?? 0
            file.modified = (attributes?[.modificationDate] as? Date) ?? Date()
            staged[path] = file
        }
    }

    /// The phone's listing plus files that exist only on the Mac so far.
    private func merged(_ files: [RemoteFile], in folder: String) -> [RemoteFile] {
        loadSavedMetadata(in: folder)
        var result = files.filter { staged[$0.path] == nil }
        for (path, file) in staged where parent(of: path) == folder {
            result.append(RemoteFile(path: path, name: (path as NSString).lastPathComponent,
                                     isDirectory: false, size: file.size, modified: file.modified))
        }
        return result
    }

    private func invalidateListing(_ folder: String) {
        listings.removeValue(forKey: folder)
    }

    private func info(_ path: String) async throws -> RemoteFile {
        if path == PhoneFiles.rootPath {
            return RemoteFile(path: path, name: "", isDirectory: true, size: 0, modified: nil)
        }
        if let file = staged[path] {
            return RemoteFile(path: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                              size: file.size, modified: file.modified)
        }
        if let cached = attributes[path],
           let listing = listings[parent(of: path)], Date().timeIntervalSince(listing.fetched) < Self.listingUsable {
            return cached
        }
        let file = try await transport { try await $0.info(path) }
        attributes[path] = file
        return file
    }

    private func transport<T: Sendable>(_ operation: (any PhoneFileTransport) async throws -> T) async throws -> T {
        do {
            return try await router.run(operation)
        } catch {
            throw Self.failure(for: error)
        }
    }

    private static func failure(for error: Error) -> NFSFailure {
        switch error {
        case let failure as NFSFailure: return failure
        case SFTPError.noSuchFile: return NFSFailure(status: .noEntry)
        case SFTPError.permissionDenied: return NFSFailure(status: .access)
        default:
            TetherLog("[NFS] \(error.localizedDescription)")
            return NFSFailure(status: .io)
        }
    }

    // MARK: - Encoding

    private func writeAttributes(_ file: RemoteFile, path: String, to writer: inout XDRWriter) {
        let time = UInt32(clamping: Int((file.modified ?? Date()).timeIntervalSince1970))
        writer.uint32(file.isDirectory ? 2 : 1)                 // type
        writer.uint32(file.isDirectory ? 0o755 : 0o644)         // mode
        writer.uint32(file.isDirectory ? 2 : 1)                 // nlink
        writer.uint32(uid)
        writer.uint32(gid)
        let size = UInt64(max(0, file.isDirectory ? 4096 : file.size))
        writer.uint64(size)                                     // size
        writer.uint64(size)                                     // used
        writer.uint32(0); writer.uint32(0)                      // rdev
        writer.uint64(fsid)
        _ = handle(for: path)
        writer.uint64(ids[path] ?? 1)                           // fileid
        for _ in 0..<3 { writer.uint32(time); writer.uint32(0) } // atime, mtime, ctime
    }

    private func postOpAttributes(_ path: String, to writer: inout XDRWriter) async {
        if let file = try? await info(path) {
            writer.bool(true)
            writeAttributes(file, path: path, to: &writer)
        } else {
            writer.bool(false)
        }
    }

    /// wcc_data without the "before" half, which clients only use as a hint.
    private func wcc(_ path: String, to writer: inout XDRWriter) async {
        writer.bool(false)
        await postOpAttributes(path, to: &writer)
    }

    // MARK: - NFS procedures

    private func nfs(_ procedure: UInt32, _ args: inout XDRReader) async throws -> Data {
        var reply = XDRWriter()
        do {
            switch procedure {
            case 0: return Data()                                       // NULL
            case 1: try await getattr(&args, &reply)
            case 2: try await setattr(&args, &reply)
            case 3: try await lookup(&args, &reply)
            case 4: try await access(&args, &reply)
            case 6: try await read(&args, &reply)
            case 7: try await write(&args, &reply)
            case 8: try await create(&args, &reply)
            case 9: try await mkdir(&args, &reply)
            case 12: try await remove(&args, &reply, directory: false)
            case 13: try await remove(&args, &reply, directory: true)
            case 14: try await rename(&args, &reply)
            case 16: try await readdir(&args, &reply, plus: false)
            case 17: try await readdir(&args, &reply, plus: true)
            case 18: try await fsstat(&args, &reply)
            case 19: try await fsinfo(&args, &reply)
            case 20: try await pathconf(&args, &reply)
            case 21: try await commit(&args, &reply)
            default:                                                    // READLINK, SYMLINK, MKNOD, LINK
                reply.uint32(NFSStatus.notSupported.rawValue)
                reply.bool(false)
                if procedure == 10 || procedure == 11 || procedure == 15 { reply.bool(false) }
            }
        } catch let failure as NFSFailure {
            // Every failure reply starts with the status; most then carry
            // optional attributes, which "not present" satisfies.
            var error = XDRWriter()
            error.uint32(failure.status.rawValue)
            error.bool(false)
            if [2, 7, 8, 9, 12, 13, 21].contains(procedure) { error.bool(false) } // wcc_data has two halves
            if procedure == 14 { error.bool(false); error.bool(false); error.bool(false) }
            return error.data
        }
        return reply.data
    }

    private func getattr(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let path = try readHandle(&args)
        let file = try await info(path)
        reply.uint32(0)
        writeAttributes(file, path: path, to: &reply)
    }

    private func setattr(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let path = try readHandle(&args)
        let changes = try SetAttributes(&args)
        if let size = changes.size {
            let file = try await info(path)
            guard !file.isDirectory else { throw NFSFailure(status: .isDirectory) }
            let staging = try await stage(path, keepContents: size > 0)
            ftruncate(staging.descriptor, off_t(size))
            staging.size = Int64(size)
            touch(staging, path: path)
        }
        if let modified = changes.modified, let staging = staged[path] {
            staging.modified = modified
        }
        reply.uint32(0)
        await wcc(path, to: &reply)
    }

    private func lookup(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let folder = try readHandle(&args)
        let name = try args.string()
        let child: RemoteFile
        if name == "." {
            child = try await info(folder)
        } else if name == ".." {
            child = try await info(parent(of: folder))
        } else if let match = try await listing(folder).first(where: { $0.name == name }) {
            child = match
        } else {
            var failure = XDRWriter()
            failure.uint32(NFSStatus.noEntry.rawValue)
            await postOpAttributes(folder, to: &failure)
            reply = failure
            return
        }
        let childPath = name == "." ? folder : (name == ".." ? parent(of: folder) : child.path)
        reply.uint32(0)
        reply.opaque(handle(for: childPath))
        reply.bool(true)
        writeAttributes(child, path: childPath, to: &reply)
        await postOpAttributes(folder, to: &reply)
    }

    private func access(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let path = try readHandle(&args)
        let requested = try args.uint32()
        _ = try await info(path)
        reply.uint32(0)
        await postOpAttributes(path, to: &reply)
        reply.uint32(requested)
    }

    private func read(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let path = try readHandle(&args)
        let offset = Int64(clamping: try args.uint64())
        let count = Int(min(try args.uint32(), 1 << 20))

        let data: Data
        let size: Int64
        if let staging = staged[path] {
            size = staging.size
            var buffer = Data(count: max(0, min(count, Int(size - offset))))
            let read = buffer.withUnsafeMutableBytes { pread(staging.descriptor, $0.baseAddress, $0.count, off_t(offset)) }
            data = buffer.prefix(max(0, read))
        } else {
            let file = try await info(path)
            guard !file.isDirectory else { throw NFSFailure(status: .isDirectory) }
            size = file.size
            data = try await readRange(path, offset: offset, count: count, size: size)
        }
        reply.uint32(0)
        await postOpAttributes(path, to: &reply)
        reply.uint32(UInt32(data.count))
        reply.bool(offset + Int64(data.count) >= size)
        reply.opaque(data)
    }

    /// Serves a read from 512 KB chunks, fetching missing ones and reading ahead.
    private func readRange(_ path: String, offset: Int64, count: Int, size: Int64) async throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let end = min(offset + Int64(count), size)
        let chunkSize = Int64(Self.chunkSize)
        let first = offset / chunkSize, last = (end - 1) / chunkSize

        var result = Data()
        for index in first...last {
            let chunk = try await loadChunk(path, index: index, size: size)
            let chunkStart = index * chunkSize
            let from = Int(max(offset, chunkStart) - chunkStart)
            let to = Int(min(end, chunkStart + Int64(chunk.count)) - chunkStart)
            if from < to { result.append(chunk[chunk.startIndex + from..<chunk.startIndex + to]) }
        }

        // Read ahead only for reading in order (playing, copying), growing the
        // window as it continues. A one-off read, like a preview, fetches nothing extra.
        let previous = readPattern[path]
        let inOrder = previous.map { abs($0.end - offset) <= chunkSize } ?? false
        let window = inOrder ? min(max(2, (previous?.window ?? 0) * 2), Self.maxReadAhead) : 0
        if readPattern.count > 256 { readPattern.removeAll() }
        readPattern[path] = (end, window)
        if window > 0 {
            for ahead in (last + 1)...(last + Int64(window)) where ahead * chunkSize < size {
                if prefetching >= Self.maxPrefetches { break }
                _ = startChunkLoad(path, index: ahead, size: size, prefetch: true)
            }
        }
        stats.reads += 1
        stats.servedBytes += result.count
        stats.files.insert(path)
        return result
    }

    private func loadChunk(_ path: String, index: Int64, size: Int64) async throws -> Data {
        if let cached = chunks.get(path: path, index: index) { return cached }
        do {
            return try await startChunkLoad(path, index: index, size: size).value
        } catch {
            throw NFSFailure(status: .io)
        }
    }

    private func startChunkLoad(_ path: String, index: Int64, size: Int64, prefetch: Bool = false) -> Task<Data, Error> {
        let key = "\(index)|\(path)"
        if let loading = chunkLoads[key] { return loading }
        if let cached = chunks.get(path: path, index: index) { return Task { cached } }
        if prefetch { prefetching += 1 }
        let offset = index * Int64(Self.chunkSize)
        let length = Int(min(Int64(Self.chunkSize), size - offset))
        let router = router
        let task = Task { () throws -> Data in
            await self.beginFetch(urgent: !prefetch)
            defer { Task { await self.endFetch() } }
            return try await router.run { try await $0.read(path, offset: offset, length: length) }
        }
        chunkLoads[key] = task
        Task {
            if let data = try? await task.value {
                chunks.put(path: path, index: index, data: data)
                stats.fetchedBytes += data.count
            }
            chunkLoads.removeValue(forKey: key)
            if prefetch { prefetching -= 1 }
        }
        return task
    }

    private func beginFetch(urgent: Bool) async {
        if activeFetches < Self.maxFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { continuation in
            // What someone is waiting for goes ahead of read-ahead.
            if urgent { waitingFetches.insert(continuation, at: 0) } else { waitingFetches.append(continuation) }
        }
    }

    private func endFetch() {
        if waitingFetches.isEmpty {
            activeFetches -= 1
        } else {
            waitingFetches.removeFirst().resume() // hand the slot straight on
        }
    }

    private func write(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let path = try readHandle(&args)
        let offset = Int64(clamping: try args.uint64())
        _ = try args.uint32() // count
        _ = try args.uint32() // stable_how: we always answer UNSTABLE and upload on COMMIT
        let data = try args.opaque()

        let staging = try await stage(path, keepContents: true)
        let written = data.withUnsafeBytes { pwrite(staging.descriptor, $0.baseAddress, $0.count, off_t(offset)) }
        guard written == data.count else { throw NFSFailure(status: .io) }
        staging.size = max(staging.size, offset + Int64(data.count))
        touch(staging, path: path)

        reply.uint32(0)
        await wcc(path, to: &reply)
        reply.uint32(UInt32(data.count))
        reply.uint32(0) // UNSTABLE
        reply.uint64(writeVerifier)
    }

    private func create(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let folder = try readHandle(&args)
        let name = try args.string()
        let mode = try args.uint32()
        if mode == 2 { _ = try args.fixed(8) } else { _ = try SetAttributes(&args) }
        guard name.utf8.count <= 255 else { throw NFSFailure(status: .nameTooLong) }

        let path = joinPath(try await realFolder(folder), name)
        if mode != 0, try await listing(folder).contains(where: { $0.name == name }) {
            throw NFSFailure(status: .exists)
        }
        let staging = try await stage(path, keepContents: false)
        ftruncate(staging.descriptor, 0)
        staging.size = 0
        touch(staging, path: path)
        invalidateListing(folder)

        reply.uint32(0)
        reply.bool(true)
        reply.opaque(handle(for: path))
        await postOpAttributes(path, to: &reply)
        await wcc(folder, to: &reply)
    }

    private func mkdir(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let folder = try readHandle(&args)
        let name = try args.string()
        _ = try SetAttributes(&args)
        let real = try await realFolder(folder)
        let directory = try await transport { try await $0.makeDirectory(folder: real, name: name) }
        attributes[directory.path] = directory
        invalidateListing(folder)

        reply.uint32(0)
        reply.bool(true)
        reply.opaque(handle(for: directory.path))
        reply.bool(true)
        writeAttributes(directory, path: directory.path, to: &reply)
        await wcc(folder, to: &reply)
    }

    private func remove(_ args: inout XDRReader, _ reply: inout XDRWriter, directory: Bool) async throws {
        let folder = try readHandle(&args)
        let name = try args.string()
        guard let target = try await listing(folder).first(where: { $0.name == name }) else {
            throw NFSFailure(status: .noEntry)
        }
        if directory {
            guard target.isDirectory else { throw NFSFailure(status: .notDirectory) }
            let contents = try await listing(target.path, fresh: true)
            guard contents.isEmpty else { throw NFSFailure(status: .notEmpty) }
        }
        let onlyOnMac = staged[target.path] != nil && !(listings[folder]?.files.contains { $0.path == target.path } ?? false)
        if let removed = staged.removeValue(forKey: target.path), removed.persistent {
            try? FileManager.default.removeItem(at: removed.url)
        }
        if !onlyOnMac, !Self.isMacMetadata(name) {
            try await transport { try await $0.delete(target.path, isDirectory: directory) }
        }
        attributes.removeValue(forKey: target.path)
        chunks.remove(path: target.path)
        invalidateListing(folder)

        reply.uint32(0)
        await wcc(folder, to: &reply)
    }

    private func rename(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let fromFolder = try readHandle(&args)
        let fromName = try args.string()
        let toFolder = try readHandle(&args)
        let toName = try args.string()

        guard let source = try await listing(fromFolder).first(where: { $0.name == fromName }) else {
            throw NFSFailure(status: .noEntry)
        }
        let destinationFolder = try await realFolder(toFolder)
        let destination = joinPath(destinationFolder, toName)

        if let staging = staged[source.path], Self.isMacMetadata(fromName) || Self.isMacMetadata(toName) {
            // Metadata never leaves the Mac; move its saved copy along.
            staged.removeValue(forKey: source.path)
            if staging.persistent {
                let target = metadataURL(for: destination)
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: staging.url, to: target)) != nil { staging.url = target }
            }
            staged[destination] = staging
        } else {
            // Upload a file still being written before moving it.
            if staged[source.path]?.dirty == true { try await flush(source.path) }
            if let existing = try await listing(toFolder).first(where: { $0.name == toName }), existing.path != source.path {
                try await transport { try await $0.delete(existing.path, isDirectory: existing.isDirectory) }
            }
            _ = try await transport { try await $0.move(source.path, toFolder: destinationFolder, name: toName) }
            if let staging = staged.removeValue(forKey: source.path) { staged[destination] = staging }
        }
        renameHandle(from: source.path, to: destination)
        chunks.remove(path: source.path)
        attributes.removeValue(forKey: source.path)
        invalidateListing(fromFolder)
        invalidateListing(toFolder)

        reply.uint32(0)
        await wcc(fromFolder, to: &reply)
        await wcc(toFolder, to: &reply)
    }

    private func readdir(_ args: inout XDRReader, _ reply: inout XDRWriter, plus: Bool) async throws {
        let folder = try readHandle(&args)
        let cookie = Int(clamping: try args.uint64())
        _ = try args.fixed(8) // cookie verifier
        let dirCount = Int(clamping: try args.uint32())
        let maxCount = plus ? Int(try args.uint32()) : dirCount
        // Leave room for the reply header and trailing fields.
        let budget = max(maxCount - 512, 1024)

        let files = try await listing(folder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let entries: [(name: String, path: String, file: RemoteFile)] =
            [(".", folder, try await info(folder)), ("..", parent(of: folder), try await info(parent(of: folder)))]
            + files.map { ($0.name, $0.path, $0) }

        reply.uint32(0)
        await postOpAttributes(folder, to: &reply)
        reply.uint64(1) // cookie verifier

        var used = 0
        var index = cookie
        while index < entries.count {
            let entry = entries[index]
            var item = XDRWriter()
            item.bool(true)
            _ = handle(for: entry.path)
            item.uint64(ids[entry.path] ?? 1)
            item.string(entry.name)
            item.uint64(UInt64(index + 1))
            if plus {
                item.bool(true)
                writeAttributes(entry.file, path: entry.path, to: &item)
                item.bool(true)
                item.opaque(handle(for: entry.path))
            }
            if used + item.data.count > budget, index > cookie { break }
            used += item.data.count
            reply.append(item)
            index += 1
        }
        reply.bool(false)
        reply.bool(index >= entries.count)
    }

    private func fsstat(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let path = try readHandle(&args)
        reply.uint32(0)
        await postOpAttributes(path, to: &reply)
        // The phone's free space isn't available over SFTP v3; report a large volume
        // so Finder doesn't refuse copies.
        let total: UInt64 = 1 << 40, free: UInt64 = 1 << 39
        reply.uint64(total); reply.uint64(free); reply.uint64(free)
        reply.uint64(1 << 30); reply.uint64(1 << 29); reply.uint64(1 << 29)
        reply.uint32(0)
    }

    private func fsinfo(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let path = try readHandle(&args)
        reply.uint32(0)
        await postOpAttributes(path, to: &reply)
        for value: UInt32 in [1 << 20, 1 << 20, 4096, 1 << 20, 1 << 20, 4096, 64 * 1024] { reply.uint32(value) }
        reply.uint64(UInt64(Int64.max))
        reply.uint32(1); reply.uint32(0) // time delta: 1 s
        reply.uint32(0x08 | 0x10)       // homogeneous, can set time
    }

    private func pathconf(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let path = try readHandle(&args)
        reply.uint32(0)
        await postOpAttributes(path, to: &reply)
        reply.uint32(1)      // link max
        reply.uint32(255)    // name max
        reply.bool(true)     // no truncation
        reply.bool(true)     // chown restricted
        reply.bool(false)    // case insensitive
        reply.bool(true)     // case preserving
    }

    private func commit(_ args: inout XDRReader, _ reply: inout XDRWriter) async throws {
        let path = try readHandle(&args)
        try await flush(path)
        reply.uint32(0)
        await wcc(path, to: &reply)
        reply.uint64(writeVerifier)
    }

    // MARK: - Writing

    /// The real phone folder behind a handle; the root maps to the storage volume.
    private func realFolder(_ folder: String) async throws -> String {
        guard folder == PhoneFiles.rootPath else { return folder }
        if volumeRoot == nil { _ = try await listing(folder) }
        guard let volumeRoot else { throw NFSFailure(status: .access) } // several volumes: pick one first
        return volumeRoot
    }

    /// The local copy of a file being written, creating it if needed.
    private func stage(_ path: String, keepContents: Bool) async throws -> Staged {
        if let existing = staged[path] { return existing }
        let isMetadata = Self.isMacMetadata((path as NSString).lastPathComponent)
        let url = isMetadata ? metadataURL(for: path) : stagingDirectory.appendingPathComponent(UUID().uuidString)
        if isMetadata {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { throw NFSFailure(status: .io) }
        let staging = Staged(url: url, descriptor: descriptor)
        staging.persistent = isMetadata
        if isMetadata {
            staged[path] = staging
            return staging
        }

        if keepContents, let file = try? await info(path), !file.isDirectory, file.size > 0 {
            // Changing part of an existing file: start from its current contents.
            try await transport { try await $0.download(path, to: descriptor) }
            staging.size = file.size
        }
        staged[path] = staging
        return staging
    }

    private func touch(_ staging: Staged, path: String) {
        staging.dirty = true
        staging.generation += 1
        staging.lastWrite = Date()
        staging.modified = Date()
        chunks.remove(path: path)
        // Upload once writes stop, in case the client never commits.
        Task {
            try? await Task.sleep(for: .seconds(4))
            if staging.dirty, Date().timeIntervalSince(staging.lastWrite) >= 3.5 { try? await flush(path) }
        }
    }

    /// Uploads a staged file to the phone.
    private func flush(_ path: String) async throws {
        guard let staging = staged[path], staging.dirty else { return }
        let name = (path as NSString).lastPathComponent
        if Self.isMacMetadata(name) {
            staging.dirty = false
            return
        }
        if let running = staging.upload {
            // That upload may have started before the latest writes; once it
            // ends, send again if anything is still unsent.
            try await running.value
            try await flush(path)
            return
        }
        let folder = parent(of: path)
        let real = (path as NSString).deletingLastPathComponent // staged paths are real phone paths
        let descriptor = staging.descriptor, size = staging.size, modified = staging.modified
        let generation = staging.generation
        let router = router
        let upload = Task {
            _ = try await router.run {
                try await $0.upload(from: descriptor, size: size, folder: real, name: name, modified: modified)
            }
        }
        staging.upload = upload
        do {
            try await upload.value
            staging.upload = nil
            if staging.generation == generation { staging.dirty = false }
            invalidateListing(folder)
            // Keep the local copy briefly for reads; drop it once idle.
            Task {
                try? await Task.sleep(for: .seconds(30))
                if let current = staged[path], current === staging, !current.dirty { staged.removeValue(forKey: path) }
            }
        } catch {
            staging.upload = nil
            TetherLog("[NFS] Upload of \(name) failed: \(error.localizedDescription)")
            throw NFSFailure(status: .io)
        }
    }
}

/// The settable attributes in SETATTR, CREATE and MKDIR (sattr3).
private nonisolated struct SetAttributes {
    var size: UInt64?
    var modified: Date?

    init(_ args: inout XDRReader) throws {
        if try args.bool() { _ = try args.uint32() } // mode
        if try args.bool() { _ = try args.uint32() } // uid
        if try args.bool() { _ = try args.uint32() } // gid
        if try args.bool() { size = try args.uint64() }
        switch try args.uint32() {                    // atime
        case 2: _ = try args.uint32(); _ = try args.uint32()
        default: break
        }
        switch try args.uint32() {                    // mtime
        case 1: modified = Date()
        case 2:
            let seconds = try args.uint32()
            _ = try args.uint32()
            modified = Date(timeIntervalSince1970: TimeInterval(seconds))
        default: break
        }
    }
}

/// Recently read chunks of phone files, least recently used dropped first.
private nonisolated struct ChunkCache {
    private var entries: [String: (data: Data, used: UInt64)] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    let limit: Int

    init(limit: Int) { self.limit = limit }

    mutating func get(path: String, index: Int64) -> Data? {
        let key = "\(index)|\(path)"
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key] = (entry.data, clock)
        return entry.data
    }

    mutating func put(path: String, index: Int64, data: Data) {
        clock += 1
        let key = "\(index)|\(path)"
        bytes -= entries[key]?.data.count ?? 0
        entries[key] = (data, clock)
        bytes += data.count
        while bytes > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            entries.removeValue(forKey: oldest.key)
            bytes -= oldest.value.data.count
        }
    }

    mutating func remove(path: String) {
        for key in entries.keys where key.hasSuffix("|" + path) {
            bytes -= entries[key]?.data.count ?? 0
            entries.removeValue(forKey: key)
        }
    }
}

private final class WeakServer: @unchecked Sendable {
    weak var server: PhoneNFSServer?
}
