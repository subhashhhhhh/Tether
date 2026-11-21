//
//  FingerprintFormat.swift
//  Tether
//
//  Certificate fingerprints laid out for comparing by eye.
//

import Foundation

enum FingerprintFormat {
    /// Splits a colon-separated SHA-256 fingerprint into four rows of eight bytes
    /// so a person can compare it at a glance.
    static func rows(_ fingerprint: String) -> [String] {
        let bytes = fingerprint.uppercased().split(separator: ":").map(String.init)
        return stride(from: 0, to: bytes.count, by: 8).map {
            bytes[$0..<min($0 + 8, bytes.count)].joined(separator: " ")
        }
    }
}
