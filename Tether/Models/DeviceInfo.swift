//
//  DeviceInfo.swift
//  Tether
//

import Foundation

public enum DeviceType: String, Codable, Sendable {
    case desktop
    case laptop
    case phone
    case tablet
    case tv
    case unknown

    public static func from(string: String) -> DeviceType {
        let lower = string.lowercased()
        if lower == "phone" || lower == "smartphone" {
            return .phone
        } else if lower == "tablet" {
            return .tablet
        } else if lower == "laptop" {
            return .laptop
        } else if lower == "desktop" {
            return .desktop
        } else if lower == "tv" {
            return .tv
        }
        return .unknown
    }

    public var systemImageName: String {
        switch self {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        case .tv: return "tv"
        case .unknown: return "display"
        }
    }
}

public struct DeviceInfo: Codable, Sendable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public var deviceName: String
    public var deviceType: DeviceType
    public var protocolVersion: Int
    public var incomingCapabilities: Set<String>
    public var outgoingCapabilities: Set<String>
    public var tcpPort: Int?

    public init(
        deviceId: String,
        deviceName: String,
        deviceType: DeviceType = .laptop,
        protocolVersion: Int = NetworkPacket.protocolVersion,
        incomingCapabilities: Set<String> = DeviceInfo.defaultIncomingCapabilities,
        outgoingCapabilities: Set<String> = DeviceInfo.defaultOutgoingCapabilities,
        tcpPort: Int? = 1716
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.protocolVersion = protocolVersion
        self.incomingCapabilities = incomingCapabilities
        self.outgoingCapabilities = outgoingCapabilities
        self.tcpPort = tcpPort
    }

    /// Packet types we accept. A peer only sends a type that appears here.
    public static let defaultIncomingCapabilities: Set<String> = [
        PacketType.ping,
        PacketType.notification,
        PacketType.notificationRequest,
        PacketType.notificationReply,
        PacketType.clipboard,
        PacketType.clipboardConnect,
        PacketType.battery,
        // Media control: state reports from the peer's player.
        PacketType.mpris,
        // The phone's Multimedia control driving this Mac
        PacketType.mprisRequest,
        // Peer volume reporting.
        PacketType.systemvolume,
        // The phone's volume panel controlling this Mac
        PacketType.systemvolumeRequest,
        // Lock state reports.
        PacketType.lock,
        // Cellular signal reports.
        PacketType.connectivityReport,
        // Call and message events.
        PacketType.telephony,
        // File, text, and URL sharing
        PacketType.shareRequest,
        PacketType.shareRequestUpdate,
        // Remote input and presenter
        PacketType.mousepadRequest,
        PacketType.presenter,
        // SMS messages and attachments
        PacketType.smsMessages,
        PacketType.smsAttachmentFile,
        // Contacts, as vCards
        PacketType.contactsResponseUidsTimestamps,
        PacketType.contactsResponseVcards,
        // Phone storage, for Finder
        PacketType.sftp,
        // Remote commands
        PacketType.runcommandRequest,
        // The phone ringing this Mac
        PacketType.findmyphoneRequest,
    ]

    /// Packet types we emit. A peer only accepts a type that appears here.
    public static let defaultOutgoingCapabilities: Set<String> = [
        PacketType.ping,
        PacketType.notification,
        PacketType.notificationRequest,
        PacketType.notificationReply,
        PacketType.notificationAction,
        PacketType.clipboard,
        PacketType.clipboardConnect,
        PacketType.battery,
        // Media transport and state queries.
        PacketType.mprisRequest,
        // This Mac as a player in the phone's Multimedia control
        PacketType.mpris,
        // Ring request.
        PacketType.findmyphoneRequest,
        // Peer volume queries and changes.
        PacketType.systemvolumeRequest,
        // This Mac's volume, for the phone's volume panel
        PacketType.systemvolume,
        // Lock and lock-state requests.
        PacketType.lockRequest,
        // File, text, and URL sharing
        PacketType.shareRequest,
        // Remote input keyboard state and echo
        PacketType.mousepadKeyboardstate,
        PacketType.mousepadEcho,
        // SMS requests
        PacketType.smsRequest,
        PacketType.sftpRequest,
        PacketType.smsRequestConversations,
        PacketType.smsRequestConversation,
        PacketType.smsRequestAttachment,
        // Contacts
        PacketType.contactsRequestAllUidsTimestamps,
        PacketType.contactsRequestVcardsByUid,
        // Silencing the ringer from an incoming-call notification
        PacketType.telephonyRequestMute,
        // Remote commands
        PacketType.runcommand,
        PacketType.runcommandOutput
    ]

    // Create UDP discovery packet
    public func toUdpDiscoveryPacket() -> NetworkPacket {
        var body: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "deviceType": deviceType.rawValue,
            "protocolVersion": protocolVersion
        ]
        if let port = tcpPort {
            body["tcpPort"] = port
        }
        return NetworkPacket(type: PacketType.identity, body: body)
    }

    // Create TCP initial connection packet
    public func toConnectionPacket(targetDeviceId: String, targetProtocolVersion: Int) -> NetworkPacket {
        let body: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "deviceType": deviceType.rawValue,
            "protocolVersion": protocolVersion,
            "targetDeviceId": targetDeviceId,
            "targetProtocolVersion": targetProtocolVersion
        ]
        return NetworkPacket(type: PacketType.identity, body: body)
    }

    // Create full encrypted identity packet
    public func toFullIdentityPacket() -> NetworkPacket {
        let body: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "deviceType": deviceType.rawValue,
            "protocolVersion": protocolVersion,
            "incomingCapabilities": Array(incomingCapabilities),
            "outgoingCapabilities": Array(outgoingCapabilities)
        ]
        return NetworkPacket(type: PacketType.identity, body: body)
    }

    static let validTCPPorts = 1...Int(UInt16.max)
    /// KDE Connect's own rules for an identity, so a malformed one from the
    /// network is turned away here as it is by the other KDE Connect apps.
    static let minimumProtocolVersion = 8

    static func isValidDeviceId(_ id: String) -> Bool {
        (32...38).contains(id.count)
            && id.unicodeScalars.allSatisfy { ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "_" || $0 == "-" }
    }

    /// The name with the characters KDE Connect leaves out, cut to 32.
    static func cleanName(_ name: String) -> String {
        let removed = Set("\"',;:.!?()[]<>")
        let cleaned = String(name.filter { !removed.contains($0) && !$0.isNewline })
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(32))
    }

    // Parse from packet
    public static func from(packet: NetworkPacket) -> DeviceInfo? {
        guard packet.type == PacketType.identity,
              let deviceId = packet.string(for: "deviceId"),
              isValidDeviceId(deviceId) else {
            return nil
        }

        let cleaned = cleanName(packet.string(for: "deviceName") ?? "")
        let name = cleaned.isEmpty ? "Unknown Device" : cleaned
        let rawType = packet.string(for: "deviceType") ?? "unknown"
        let type = DeviceType.from(string: rawType)
        let version = packet.int(for: "protocolVersion", default: NetworkPacket.protocolVersion)
        guard version >= minimumProtocolVersion else { return nil }
        let incoming = Set(packet.stringArray(for: "incomingCapabilities"))
        let outgoing = Set(packet.stringArray(for: "outgoingCapabilities"))
        // The identity arrives over UDP before anything is verified, so a port
        // that can't be dialled drops the whole packet rather than reaching connect().
        var port: Int?
        if packet.body["tcpPort"] != nil {
            let claimed = packet.int(for: "tcpPort")
            guard Self.validTCPPorts.contains(claimed) else { return nil }
            port = claimed
        }

        return DeviceInfo(
            deviceId: deviceId,
            deviceName: name,
            deviceType: type,
            protocolVersion: version,
            incomingCapabilities: incoming,
            outgoingCapabilities: outgoing,
            tcpPort: port
        )
    }
}
