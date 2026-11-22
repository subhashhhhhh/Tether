//
//  TransferItem.swift
//  Tether
//

import Foundation

nonisolated enum TransferDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

nonisolated enum TransferStatus: Equatable, Sendable {
    case queued
    case transferring
    case completed
    case failed(String)
    case cancelled
}

nonisolated struct TransferItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let deviceId: String
    let deviceName: String
    let filename: String
    let totalBytes: Int64
    var transferredBytes: Int64
    let direction: TransferDirection
    var status: TransferStatus
    var progress: Double
    var speedBytesPerSec: Double
    let timestamp: Date
    var localURL: URL?

    init(
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

}
