//
//  PairState.swift
//  Tether
//

import Foundation

enum PairState: String, Codable, Sendable {
    case notPaired
    case requested
    case requestedByPeer
    case paired

}
