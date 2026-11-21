//
//  SFTPClient.swift
//  Tether
//
//  SFTP version 3 (draft-ietf-secsh-filexfer-02), the version KDE Connect's
//  Android server speaks, over an SSHConnection. Reads and writes are
//  pipelined: many requests are in flight at once, which matters most on
//  high-latency links such as a Tailscale relay.
//

import Foundation

nonisolated enum SFTPError: LocalizedError, Equatable {
    case noSuchFile
    case permissionDenied
    case failure(String)
    case badMessage

    var errorDescription: String? {
        switch self {
        case .noSuchFile: "The file doesn't exist on the phone."
        case .permissionDenied: "The phone doesn't allow access to this file."
        case .failure(let message): message.isEmpty ? "The phone couldn't complete the file operation." : message
        case .badMessage: "The phone sent a malformed file response."
        }
    }
}

private nonisolated enum Packet {
    static let initialize: UInt8 = 1
    static let version: UInt8 = 2
    static let open: UInt8 = 3
    static let close: UInt8 = 4
    static let read: UInt8 = 5
    static let write: UInt8 = 6
    static let lstat: UInt8 = 7
    static let openDirectory: UInt8 = 11
    static let readDirectory: UInt8 = 12
    static let remove: UInt8 = 13
    static let makeDirectory: UInt8 = 14
    static let removeDirectory: UInt8 = 15
    static let stat: UInt8 = 17
    static let rename: UInt8 = 18
    static let status: UInt8 = 101
    static let handle: UInt8 = 102
    static let data: UInt8 = 103
    static let name: UInt8 = 104
    static let attributes: UInt8 = 105
}

private nonisolated enum OpenFlag {
    static let read: UInt32 = 0x01
    static let write: UInt32 = 0x02
    static let create: UInt32 = 0x08
    static let truncate: UInt32 = 0x10
}

private nonisolated struct Attributes {
    var size: Int64?
    var permissions: UInt32?
    var modified: Date?

    var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }

    init(reader: inout SSHReader) throws {
        let flags = try reader.uint32()
        if flags & 0x1 != 0 { size = Int64(bitPattern: try reader.uint64()) }
        if flags & 0x2 != 0 { _ = try reader.uint32(); _ = try reader.uint32() }
        if flags & 0x4 != 0 { permissions = try reader.uint32() }
        if flags & 0x8 != 0 {
            _ = try reader.uint32()
            modified = Date(timeIntervalSince1970: TimeInterval(try reader.uint32()))
        }
        if flags & 0x8000_0000 != 0 {
            for _ in 0..<(try reader.uint32()) {
                _ = try reader.string()
                _ = try reader.string()
            }
        }
    }

    static func write(modified: Date?, to writer: inout SSHWriter) {
        guard let modified else { return writer.uint32(0) }
        let seconds = UInt32(clamping: Int(modified.timeIntervalSince1970))
        writer.uint32(0x8)
        writer.uint32(seconds)
        writer.uint32(seconds)
    }
}

actor SFTPClient {
    /// Bytes per READ or WRITE request, and how many are kept in flight.
    private static let chunkSize = 32 * 1024
    private static let pipelineDepth = 64

    private let connection: SSHConnection
    private var nextRequestID: UInt32 = 0
    private var pending: [UInt32: CheckedContinuation<Data, Error>] = [:]
    private var closedError: Error?
    private var readerTask: Task<Void, Never>?

    private init(connection: SSHConnection) {
        self.connection = connection
    }

    static func connect(
        host: String, port: UInt16, user: String, password: String,
        checkHostKey: @escaping @Sendable (SSHHostKey) -> Bool
    ) async throws -> SFTPClient {
        let connection = SSHConnection(host: host, port: port, checkHostKey: checkHostKey)
        let stream: AsyncThrowingStream<Data, Error>
        do {
            stream = try await connection.openSFTP(user: user, password: password)
        } catch {
            await connection.close()
            throw error
        }
        let client = SFTPClient(connection: connection)
        try await client.start(stream)
        return client
    }

    private func start(_ stream: AsyncThrowingStream<Data, Error>) async throws {
        var initialize = SSHWriter()
        initialize.byte(Packet.initialize)
        initialize.uint32(3)
        try await connection.write(Self.frame(initialize.data))

        // The VERSION reply has no request ID, so read it before the dispatcher starts.
        var buffer = Data()
        var iterator = stream.makeAsyncIterator()
        var version: Data?
        while version == nil {
            guard let chunk = try await iterator.next() else { throw SSHError.disconnected("no SFTP version") }
            buffer.append(chunk)
            version = Self.takeFrame(from: &buffer)
        }
        guard version?.first == Packet.version else { throw SFTPError.badMessage }

        let leftover = buffer
        readerTask = Task { [iterator] in
            var iterator = iterator
            var buffer = leftover
            do {
                while true {
                    while let frame = Self.takeFrame(from: &buffer) { self.deliver(frame) }
                    guard let chunk = try await iterator.next() else { break }
                    buffer.append(chunk)
                }
                self.failAll(SSHError.disconnected("the file session ended"))
            } catch {
                self.failAll(error)
            }
        }
    }

    func close() async {
        readerTask?.cancel()
        failAll(SSHError.disconnected("closed"))
        await connection.close()
    }

    var isClosed: Bool { closedError != nil }

    // MARK: - Framing and dispatch

    private static func frame(_ payload: Data) -> Data {
        UInt32(payload.count).bigEndianData + payload
    }

    private static func takeFrame(from buffer: inout Data) -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard buffer.count >= 4 + length else { return nil }
        let frame = Data(buffer.dropFirst(4).prefix(length))
        buffer.removeFirst(4 + length)
        return frame
    }

    private func deliver(_ frame: Data) {
        guard frame.count >= 5 else { return }
        let id = frame.dropFirst().prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        pending.removeValue(forKey: id)?.resume(returning: frame)
    }

    private func failAll(_ error: Error) {
        if closedError == nil { closedError = error }
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    /// Sends one request and waits for its reply. `build` writes the fields after the ID.
    private func request(_ type: UInt8, _ build: (inout SSHWriter) -> Void) async throws -> Data {
        if let closedError { throw closedError }
        let id = nextRequestID
        nextRequestID &+= 1
        var writer = SSHWriter()
        writer.byte(type)
        writer.uint32(id)
        build(&writer)
        let packet = Self.frame(writer.data)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await self.connection.write(packet)
                } catch {
                    self.pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        }
    }

    /// Throws unless the reply is STATUS OK. EOF counts as OK when `eofIsOK`.
    private static func checkStatus(_ reply: Data, eofIsOK: Bool = false) throws {
        var reader = SSHReader(reply)
        guard try reader.byte() == Packet.status else { throw SFTPError.badMessage }
        _ = try reader.uint32()
        let code = try reader.uint32()
        let message = (try? reader.utf8()) ?? ""
        switch code {
        case 0: return
        case 1 where eofIsOK: return
        case 2: throw SFTPError.noSuchFile
        case 3: throw SFTPError.permissionDenied
        default: throw SFTPError.failure(message)
        }
    }

    private func handle(from reply: Data) throws -> Data {
        var reader = SSHReader(reply)
        let type = try reader.byte()
        if type == Packet.status { try Self.checkStatus(reply); throw SFTPError.badMessage }
        guard type == Packet.handle else { throw SFTPError.badMessage }
        _ = try reader.uint32()
        return try reader.string()
    }

    private func closeHandle(_ handle: Data) async {
        _ = try? await request(Packet.close) { $0.string(handle) }
    }

    // MARK: - Operations

    func list(_ path: String) async throws -> [RemoteFile] {
        let handle = try handle(from: try await request(Packet.openDirectory) { $0.string(path) })
        var files: [RemoteFile] = []
        do {
            while true {
                let reply = try await request(Packet.readDirectory) { $0.string(handle) }
                var reader = SSHReader(reply)
                let type = try reader.byte()
                if type == Packet.status {
                    try Self.checkStatus(reply, eofIsOK: true)
                    break
                }
                guard type == Packet.name else { throw SFTPError.badMessage }
                _ = try reader.uint32()
                for _ in 0..<(try reader.uint32()) {
                    let name = try reader.utf8()
                    _ = try reader.string() // long name
                    let attributes = try Attributes(reader: &reader)
                    guard name != ".", name != ".." else { continue }
                    files.append(RemoteFile(
                        path: Self.join(path, name), name: name, isDirectory: attributes.isDirectory,
                        size: attributes.size ?? 0, modified: attributes.modified
                    ))
                }
            }
        } catch {
            await closeHandle(handle)
            throw error
        }
        await closeHandle(handle)
        return files
    }

    func stat(_ path: String) async throws -> RemoteFile {
        let reply = try await request(Packet.stat) { $0.string(path) }
        var reader = SSHReader(reply)
        let type = try reader.byte()
        if type == Packet.status { try Self.checkStatus(reply); throw SFTPError.badMessage }
        guard type == Packet.attributes else { throw SFTPError.badMessage }
        _ = try reader.uint32()
        let attributes = try Attributes(reader: &reader)
        let name = (path as NSString).lastPathComponent
        return RemoteFile(path: path, name: name, isDirectory: attributes.isDirectory,
                          size: attributes.size ?? 0, modified: attributes.modified)
    }

    /// Writes the remote file into `fileDescriptor` from offset 0, keeping
    /// many reads in flight. Returns the number of bytes written.
    func download(_ path: String, to fileDescriptor: Int32, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let handle = try handle(from: try await request(Packet.open) {
            $0.string(path)
            $0.uint32(OpenFlag.read)
            $0.uint32(0)
        })

        do {
            var total: Int64 = 0
            try await withThrowingTaskGroup(of: (Int64, Int, Int).self) { group in
                var nextOffset: Int64 = 0
                var reachedEnd = false
                var inFlight = 0

                func schedule(_ offset: Int64, _ length: Int) {
                    inFlight += 1
                    group.addTask { try await self.readChunk(handle, offset: offset, length: length, into: fileDescriptor) }
                }
                for _ in 0..<Self.pipelineDepth {
                    schedule(nextOffset, Self.chunkSize)
                    nextOffset += Int64(Self.chunkSize)
                }
                while inFlight > 0, let (offset, requested, got) = try await group.next() {
                    inFlight -= 1
                    if got < 0 {
                        reachedEnd = true // EOF at `offset`
                        continue
                    }
                    total += Int64(got)
                    progress(total)
                    if got < requested {
                        // A short read: fetch the rest of this request.
                        schedule(offset + Int64(got), requested - got)
                    } else if !reachedEnd {
                        schedule(nextOffset, Self.chunkSize)
                        nextOffset += Int64(Self.chunkSize)
                    }
                }
            }
            await closeHandle(handle)
            return total
        } catch {
            await closeHandle(handle)
            throw error
        }
    }

    /// Reads one chunk and writes it at its offset. Returns (offset, requested,
    /// bytes read), with -1 bytes at end of file.
    private func readChunk(_ handle: Data, offset: Int64, length: Int, into fileDescriptor: Int32) async throws -> (Int64, Int, Int) {
        let reply = try await request(Packet.read) {
            $0.string(handle)
            $0.uint64(UInt64(offset))
            $0.uint32(UInt32(length))
        }
        var reader = SSHReader(reply)
        let type = try reader.byte()
        if type == Packet.status {
            try Self.checkStatus(reply, eofIsOK: true)
            return (offset, length, -1)
        }
        guard type == Packet.data else { throw SFTPError.badMessage }
        _ = try reader.uint32()
        let data = try reader.string()
        guard !data.isEmpty else { return (offset, length, -1) }
        let written = data.withUnsafeBytes { pwrite(fileDescriptor, $0.baseAddress, data.count, off_t(offset)) }
        guard written == data.count else { throw SFTPError.failure("Couldn't write the downloaded file.") }
        return (offset, length, data.count)
    }

    /// Uploads `size` bytes from `fileDescriptor` (read from offset 0) to `path`,
    /// replacing it, then sets its modification date.
    func upload(from fileDescriptor: Int32, size: Int64, to path: String, modified: Date?,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
        let handle = try handle(from: try await request(Packet.open) {
            $0.string(path)
            $0.uint32(OpenFlag.write | OpenFlag.create | OpenFlag.truncate)
            $0.uint32(0)
        })

        do {
            try await withThrowingTaskGroup(of: Int.self) { group in
                var nextOffset: Int64 = 0
                var inFlight = 0
                var sent: Int64 = 0

                func scheduleNext() throws {
                    guard nextOffset < size else { return }
                    let length = Int(min(Int64(Self.chunkSize), size - nextOffset))
                    var buffer = Data(count: length)
                    let read = buffer.withUnsafeMutableBytes { pread(fileDescriptor, $0.baseAddress, length, off_t(nextOffset)) }
                    guard read == length else { throw SFTPError.failure("Couldn't read the file to upload.") }
                    let offset = nextOffset
                    nextOffset += Int64(length)
                    inFlight += 1
                    group.addTask {
                        let reply = try await self.request(Packet.write) {
                            $0.string(handle)
                            $0.uint64(UInt64(offset))
                            $0.string(buffer)
                        }
                        try Self.checkStatus(reply)
                        return length
                    }
                }
                for _ in 0..<Self.pipelineDepth { try scheduleNext() }
                while inFlight > 0, let length = try await group.next() {
                    inFlight -= 1
                    sent += Int64(length)
                    progress(sent)
                    try scheduleNext()
                }
            }
            await closeHandle(handle)
        } catch {
            await closeHandle(handle)
            throw error
        }

        if let modified {
            // Keep the Mac's modification date; a phone that refuses is fine.
            _ = try? await request(9) { // SETSTAT
                $0.string(path)
                Attributes.write(modified: modified, to: &$0)
            }
        }
    }

    /// Opens a file for random-access reads; close it with `closeFile`.
    func openForReading(_ path: String) async throws -> Data {
        try handle(from: try await request(Packet.open) {
            $0.string(path)
            $0.uint32(OpenFlag.read)
            $0.uint32(0)
        })
    }

    func closeFile(_ handle: Data) async {
        await closeHandle(handle)
    }

    /// Up to `length` bytes at `offset`, fewer only at the end of the file.
    /// The 32 KB requests that make it up are sent all at once, so a 512 KB
    /// read costs one round trip rather than sixteen.
    func read(_ handle: Data, offset: Int64, length: Int) async throws -> Data {
        let pieces = stride(from: 0, to: length, by: Self.chunkSize).map { start in
            (offset: offset + Int64(start), length: min(Self.chunkSize, length - start))
        }
        let results = try await withThrowingTaskGroup(of: (Int, Data?).self) { group in
            for (index, piece) in pieces.enumerated() {
                group.addTask { (index, try await self.readOnce(handle, offset: piece.offset, length: piece.length)) }
            }
            var results = [Data?](repeating: nil, count: pieces.count)
            for try await (index, data) in group { results[index] = data }
            return results
        }

        var result = Data()
        for (index, piece) in pieces.enumerated() {
            guard let data = results[index] else { break } // end of file
            result.append(data)
            if data.count < piece.length {
                // A short read: fetch the rest of this piece, then stop if the file ended.
                var position = piece.offset + Int64(data.count)
                let pieceEnd = piece.offset + Int64(piece.length)
                while position < pieceEnd, let more = try await readOnce(handle, offset: position, length: Int(pieceEnd - position)), !more.isEmpty {
                    result.append(more)
                    position += Int64(more.count)
                }
                if position < pieceEnd { break }
            }
        }
        return result
    }

    /// One READ request; nil at the end of the file.
    private func readOnce(_ handle: Data, offset: Int64, length: Int) async throws -> Data? {
        let reply = try await request(Packet.read) {
            $0.string(handle)
            $0.uint64(UInt64(offset))
            $0.uint32(UInt32(length))
        }
        var reader = SSHReader(reply)
        let type = try reader.byte()
        if type == Packet.status {
            try Self.checkStatus(reply, eofIsOK: true)
            return nil
        }
        guard type == Packet.data else { throw SFTPError.badMessage }
        _ = try reader.uint32()
        let data = try reader.string()
        return data.isEmpty ? nil : data
    }

    /// Reads several ranges of an open file at once (pipelined).
    func read(_ handle: Data, ranges: [(offset: Int64, length: Int)]) async throws -> [Data] {
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, range) in ranges.enumerated() {
                group.addTask { (index, try await self.read(handle, offset: range.offset, length: range.length)) }
            }
            var results = [Data](repeating: Data(), count: ranges.count)
            for try await (index, data) in group { results[index] = data }
            return results
        }
    }

    func makeDirectory(_ path: String) async throws {
        try Self.checkStatus(try await request(Packet.makeDirectory) {
            $0.string(path)
            $0.uint32(0)
        })
    }

    func removeFile(_ path: String) async throws {
        try Self.checkStatus(try await request(Packet.remove) { $0.string(path) })
    }

    func removeDirectory(_ path: String) async throws {
        try Self.checkStatus(try await request(Packet.removeDirectory) { $0.string(path) })
    }

    /// Deletes a folder and everything in it.
    func removeRecursively(_ path: String) async throws {
        for entry in try await list(path) {
            if entry.isDirectory {
                try await removeRecursively(entry.path)
            } else {
                try await removeFile(entry.path)
            }
        }
        try await removeDirectory(path)
    }

    func rename(_ from: String, to: String) async throws {
        try Self.checkStatus(try await request(Packet.rename) {
            $0.string(from)
            $0.string(to)
        })
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
