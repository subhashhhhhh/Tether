//
//  String+Preview.swift
//  Tether
//

import Foundation

extension String {
    /// The first line, trimmed and cut to `limit` characters with "…".
    func firstLine(limit: Int) -> String {
        let line = split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// Every line joined with spaces, so a short preview uses the full width
    /// instead of stopping at an early line break.
    var joinedLines: String {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
