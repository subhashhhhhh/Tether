//
//  PhoneSIM.swift
//  Tether
//

import Foundation

/// A SIM in the phone, as its connectivity report lists them. The phone gives
/// only Android's subscription id and the network type, not the carrier or
/// the number, so SIMs are numbered in id order and can be named in Tether.
public struct PhoneSIM: Identifiable, Hashable, Sendable {
    /// Android's subscription id, which SMS packets call `subID`/`sub_id`.
    public let id: Int64
    /// 1-based, in subscription id order.
    public let number: Int
    public let networkType: String
}

/// Names given to SIMs in Tether, stored as JSON keyed "deviceId/subId" so
/// views can watch them with @AppStorage.
enum SIMNames {
    static let key = "tether_sim_names"

    /// Decoded once per stored value: labels are read on every redraw.
    private static var lastDecoded: (json: String, names: [String: String])?

    static func decode(_ json: String) -> [String: String] {
        if let lastDecoded, lastDecoded.json == json { return lastDecoded.names }
        let names = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
        lastDecoded = (json, names)
        return names
    }

    static func label(for sim: PhoneSIM, deviceId: String, in json: String) -> String {
        decode(json)["\(deviceId)/\(sim.id)"] ?? "SIM \(sim.number)"
    }

    static func name(for sim: PhoneSIM, deviceId: String, in json: String) -> String {
        decode(json)["\(deviceId)/\(sim.id)"] ?? ""
    }

    /// The JSON with `name` set for the SIM; an empty name goes back to "SIM n".
    static func setting(_ name: String, for sim: PhoneSIM, deviceId: String, in json: String) -> String {
        var names = decode(json)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names["\(deviceId)/\(sim.id)"] = trimmed.isEmpty ? nil : trimmed
        guard let data = try? JSONEncoder().encode(names) else { return json }
        return String(decoding: data, as: UTF8.self)
    }
}
