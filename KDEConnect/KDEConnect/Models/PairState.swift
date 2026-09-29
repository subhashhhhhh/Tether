//
//  PairState.swift
//  KDEConnect
//

import Foundation

public enum PairState: String, Codable, Sendable {
    case notPaired
    case requested
    case requestedByPeer
    case paired

    public var isPaired: Bool {
        self == .paired
    }
}
