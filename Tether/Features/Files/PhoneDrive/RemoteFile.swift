//
//  RemoteFile.swift
//  Tether
//

import Foundation

nonisolated enum PhoneFiles {
    /// The top of the phone's storage as the drive shows it: the one storage
    /// volume's contents, or a folder per volume when there are several.
    static let rootPath = ""
}

/// A file or folder on the phone.
nonisolated struct RemoteFile: Codable, Sendable, Equatable {
    var path: String
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?
}
