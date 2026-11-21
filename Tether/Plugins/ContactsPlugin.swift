//
//  ContactsPlugin.swift
//  Tether
//
//  Keeps a copy of the phone's contacts so Messages and call notifications
//  show names and photos. Like desktop KDE Connect: ask for every contact's ID
//  and last-changed time, then fetch only the vCards that are new or changed.
//  The phone asks the user for contacts permission the first time.
//
//  Copies live in ~/Library/Application Support/Tether/Contacts/<device>,
//  readable only by this user, and are deleted when the device is unpaired.
//

import Foundation
import Combine

public final class ContactsPlugin: ObservableObject, TetherPlugin, @unchecked Sendable {
    static let requestAllType = "kdeconnect.contacts.request_all_uids_timestamps"
    // Singular "uid", unlike the other three: that is the name on both sides.
    static let requestVCardsType = "kdeconnect.contacts.request_vcards_by_uid"
    static let responseUIDsType = "kdeconnect.contacts.response_uids_timestamps"
    static let responseVCardsType = "kdeconnect.contacts.response_vcards"

    public let supportedPacketTypes = [responseUIDsType, responseVCardsType]

    /// Contacts per device, published on the main thread.
    @Published private(set) var books: [String: ContactBook] = [:]

    private let queue = DispatchQueue(label: "com.subhashh.tether.contacts")
    /// Last-changed time per contact ID, per device, as the phone reported it.
    private var timestamps: [String: [String: Int64]] = [:]
    private var working: [String: ContactBook] = [:]

    public init() {}

    // MARK: - Lookup

    /// The contact on `deviceId` with this phone number.
    func contact(for number: String, on deviceId: String) -> Contact? {
        books[deviceId]?.contact(for: number)
    }

    /// Same, safe from any thread (the notification plugins run off the main thread).
    func contactNow(for number: String, on deviceId: String) -> Contact? {
        queue.sync { working[deviceId]?.contact(for: number) }
    }

    // MARK: - Plugin

    public func onConnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        queue.async {
            self.loadFromDisk(deviceId)
            connection.send(packet: NetworkPacket(type: Self.requestAllType))
        }
    }

    public func onDisconnected(connection: DeviceConnection) {}

    /// Its state belongs to the device, not the connection, and is kept.
    public func onConnectionReplaced(old: DeviceConnection, new: DeviceConnection) {}

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        queue.async {
            switch packet.type {
            case Self.responseUIDsType: self.reconcile(packet, deviceId: deviceId, connection: connection)
            case Self.responseVCardsType: self.store(packet, deviceId: deviceId)
            default: break
            }
        }
    }

    /// Deletes the copy of a device's contacts, when it's unpaired.
    func forget(deviceId: String) {
        queue.async {
            self.working[deviceId] = nil
            self.timestamps[deviceId] = nil
            try? FileManager.default.removeItem(at: Self.directory(for: deviceId))
            self.publish(deviceId)
        }
    }

    // MARK: - Sync

    private func reconcile(_ packet: NetworkPacket, deviceId: String, connection: DeviceConnection) {
        let uids = packet.stringArray(for: "uids")
        let known = timestamps[deviceId] ?? [:]
        var changed: [String] = []
        for uid in uids where known[uid] != packet.int64(for: uid) {
            changed.append(uid)
        }

        // Contacts deleted on the phone.
        let removed = Set(known.keys).subtracting(uids)
        for uid in removed {
            working[deviceId, default: ContactBook()].set(nil, for: uid)
            timestamps[deviceId]?[uid] = nil
            try? FileManager.default.removeItem(at: Self.file(for: uid, deviceId: deviceId))
        }
        // Remember the phone's timestamps now; a vCard that never arrives is
        // fetched again next time because its file is missing.
        for uid in changed { timestamps[deviceId, default: [:]][uid] = packet.int64(for: uid) }
        saveIndex(deviceId)

        TetherLog("[Contacts] \(uids.count) contact(s) on the phone, \(changed.count) to fetch, \(removed.count) removed")
        if !removed.isEmpty { publish(deviceId) }
        guard !changed.isEmpty else { return }
        connection.send(packet: NetworkPacket(type: Self.requestVCardsType, body: ["uids": changed]))
    }

    private func store(_ packet: NetworkPacket, deviceId: String) {
        let directory = Self.directory(for: deviceId)
        Self.makePrivateDirectory(directory)
        var book = working[deviceId] ?? ContactBook()
        let uids = packet.stringArray(for: "uids")
        for uid in uids {
            guard let text = packet.string(for: uid) else { continue }
            try? Data(text.utf8).write(to: Self.file(for: uid, deviceId: deviceId), options: .atomic)
            book.set(VCard.parse(text), for: uid)
        }
        working[deviceId] = book
        TetherLog("[Contacts] Saved \(uids.count) contact(s)")
        publish(deviceId)
    }

    private func loadFromDisk(_ deviceId: String) {
        guard working[deviceId] == nil else { return }
        var book = ContactBook()
        var index = (try? JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: Self.indexFile(deviceId)))) ?? [:]
        for (uid, _) in index {
            guard let text = try? String(contentsOf: Self.file(for: uid, deviceId: deviceId), encoding: .utf8) else {
                index[uid] = nil // Missing file: fetch it again.
                continue
            }
            book.set(VCard.parse(text), for: uid)
        }
        timestamps[deviceId] = index
        working[deviceId] = book
        publish(deviceId)
    }

    private func saveIndex(_ deviceId: String) {
        Self.makePrivateDirectory(Self.directory(for: deviceId))
        guard let data = try? JSONEncoder().encode(timestamps[deviceId] ?? [:]) else { return }
        try? data.write(to: Self.indexFile(deviceId), options: .atomic)
    }

    private func publish(_ deviceId: String) {
        let book = working[deviceId]
        DispatchQueue.main.async { if self.books[deviceId] != book { self.books[deviceId] = book } }
    }

    // MARK: - Files

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether/Contacts", isDirectory: true)
    }

    private static func directory(for deviceId: String) -> URL {
        root.appendingPathComponent(deviceId.filter { $0.isLetter || $0.isNumber || $0 == "_" }, isDirectory: true)
    }

    private static func indexFile(_ deviceId: String) -> URL {
        directory(for: deviceId).appendingPathComponent("index.json")
    }

    /// A contact ID comes from the phone, so only its safe characters make the file name.
    private static func file(for uid: String, deviceId: String) -> URL {
        let safe = uid.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : String(format: "_%x", $0.value) }.joined()
        return directory(for: deviceId).appendingPathComponent(safe + ".vcf")
    }

    private static func makePrivateDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
