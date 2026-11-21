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
        "kdeconnect.ping",
        "kdeconnect.notification",
        "kdeconnect.notification.request",
        "kdeconnect.notification.reply",
        "kdeconnect.clipboard",
        "kdeconnect.clipboard.connect",
        "kdeconnect.battery",
        // Media control: state reports from the peer's player.
        "kdeconnect.mpris",
        // The phone's Multimedia control driving this Mac
        "kdeconnect.mpris.request",
        // Peer volume reporting.
        "kdeconnect.systemvolume",
        // The phone's volume panel controlling this Mac
        "kdeconnect.systemvolume.request",
        // Lock state reports.
        "kdeconnect.lock",
        // Cellular signal reports.
        "kdeconnect.connectivity_report",
        // Call and message events.
        "kdeconnect.telephony",
        // File, text, and URL sharing
        "kdeconnect.share.request",
        "kdeconnect.share.request.update",
        // Remote input and presenter
        "kdeconnect.mousepad.request",
        "kdeconnect.presenter",
        // SMS messages and attachments
        "kdeconnect.sms.messages",
        "kdeconnect.sms.attachment_file",
        // Contacts, as vCards
        "kdeconnect.contacts.response_uids_timestamps",
        "kdeconnect.contacts.response_vcards",
        // Phone storage, for Finder
        "kdeconnect.sftp",
        // Remote commands
        "kdeconnect.runcommand.request",
        // The phone ringing this Mac
        "kdeconnect.findmyphone.request",
    ]

    /// Packet types we emit. A peer only accepts a type that appears here.
    public static let defaultOutgoingCapabilities: Set<String> = [
        "kdeconnect.ping",
        "kdeconnect.notification",
        "kdeconnect.notification.request",
        "kdeconnect.notification.reply",
        "kdeconnect.notification.action",
        "kdeconnect.clipboard",
        "kdeconnect.clipboard.connect",
        "kdeconnect.battery",
        // Media transport and state queries.
        "kdeconnect.mpris.request",
        // This Mac as a player in the phone's Multimedia control
        "kdeconnect.mpris",
        // Ring request.
        "kdeconnect.findmyphone.request",
        // Peer volume queries and changes.
        "kdeconnect.systemvolume.request",
        // This Mac's volume, for the phone's volume panel
        "kdeconnect.systemvolume",
        // Lock and lock-state requests.
        "kdeconnect.lock.request",
        // File, text, and URL sharing
        "kdeconnect.share.request",
        // Remote input keyboard state and echo
        "kdeconnect.mousepad.keyboardstate",
        "kdeconnect.mousepad.echo",
        // SMS requests
        "kdeconnect.sms.request",
        "kdeconnect.sftp.request",
        "kdeconnect.sms.request_conversations",
        "kdeconnect.sms.request_conversation",
        "kdeconnect.sms.request_attachment",
        // Contacts
        "kdeconnect.contacts.request_all_uids_timestamps",
        "kdeconnect.contacts.request_vcards_by_uid",
        // Silencing the ringer from an incoming-call notification
        "kdeconnect.telephony.request_mute",
        // Remote commands
        "kdeconnect.runcommand",
        "kdeconnect.runcommand.output"
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
        return NetworkPacket(type: "kdeconnect.identity", body: body)
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
        return NetworkPacket(type: "kdeconnect.identity", body: body)
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
        return NetworkPacket(type: "kdeconnect.identity", body: body)
    }

    static let validTCPPorts = 1...Int(UInt16.max)

    // Parse from packet
    public static func from(packet: NetworkPacket) -> DeviceInfo? {
        guard packet.type == "kdeconnect.identity",
              let deviceId = packet.string(for: "deviceId") else {
            return nil
        }

        let name = packet.string(for: "deviceName") ?? "Unknown Device"
        let rawType = packet.string(for: "deviceType") ?? "unknown"
        let type = DeviceType.from(string: rawType)
        let version = packet.int(for: "protocolVersion", default: NetworkPacket.protocolVersion)
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
