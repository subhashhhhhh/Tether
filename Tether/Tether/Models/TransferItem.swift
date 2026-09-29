//
//  TransferItem.swift
//  Tether
//

import Foundation

public enum TransferDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

public enum TransferStatus: Equatable, Sendable {
    case queued
    case transferring
    case completed
    case failed(String)
    case cancelled
}

public struct TransferItem: Identifiable, Sendable {
    public let id: UUID
    public let deviceId: String
    public let deviceName: String
    public let filename: String
    public let totalBytes: Int64
    public var transferredBytes: Int64
    public let direction: TransferDirection
    public var status: TransferStatus
    public var progress: Double
    public var speedBytesPerSec: Double
    public let timestamp: Date
    public var localURL: URL?

    public init(
        id: UUID = UUID(),
        deviceId: String,
        deviceName: String,
        filename: String,
        totalBytes: Int64,
        transferredBytes: Int64 = 0,
        direction: TransferDirection,
        status: TransferStatus = .queued,
        progress: Double = 0.0,
        speedBytesPerSec: Double = 0.0,
        timestamp: Date = Date(),
        localURL: URL? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.filename = filename
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.direction = direction
        self.status = status
        self.progress = progress
        self.speedBytesPerSec = speedBytesPerSec
        self.timestamp = timestamp
        self.localURL = localURL
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    public var formattedProgress: String {
        let percent = Int(progress * 100)
        return "\(percent)%"
    }
}
