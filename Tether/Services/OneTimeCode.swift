//
//  OneTimeCode.swift
//  Tether
//
//  Finds a one-time verification code in a phone notification, so it can be
//  copied with one click. Only text that talks about a code is considered,
//  and amounts, dates, years and phone numbers are skipped.
//

import Foundation

nonisolated enum OneTimeCode {
    /// Settings › General › "Copy verification codes automatically". Off by
    /// default: replacing the clipboard unasked can lose what was on it.
    static let autoCopyKey = "tether_copy_codes_automatically"

    private static let keywords = [
        "code", "otp", "verification", "verify", "passcode", "password", "pin",
        "one-time", "one time", "2fa", "two-factor", "authentication", "security",
        "login", "log in", "log-in", "sign in", "sign-in", "signin", "confirm",
    ]

    /// A code in one of a notification's buttons, as Google Messages adds
    /// "Copy 123456". Any 4 to 10 digit run counts, in any language, as the
    /// desktop app does. The phone puts U+2063 between the digits.
    static func find(inAction actions: [String]) -> String? {
        for action in actions {
            let cleaned = action.replacingOccurrences(of: "\u{2063}", with: "")
            if let match = matches(#"\b(\d{4,10})\b"#, in: cleaned).first { return match.groups[1] }
        }
        return nil
    }

    /// The code in `text`, digits only, or nil.
    static func find(in text: String) -> String? {
        let lower = text.lowercased()
        // Whole words only: "pin" is not in "shipping". Each is kept as the
        // span it covers, so distance is measured from its nearer end.
        let keywordSpans: [Range<Int>] = keywords.flatMap { keyword in
            lower.ranges(of: keyword).compactMap { range -> Range<Int>? in
                if range.lowerBound > lower.startIndex, lower[lower.index(before: range.lowerBound)].isLetter { return nil }
                if range.upperBound < lower.endIndex, lower[range.upperBound].isLetter { return nil }
                return lower.distance(from: lower.startIndex, to: range.lowerBound)
                    ..< lower.distance(from: lower.startIndex, to: range.upperBound)
            }
        }
        guard !keywordSpans.isEmpty else { return nil }

        var candidates: [(code: String, position: Int)] = []

        // "G-123456": a short prefix that sites don't expect you to type.
        for (groups, position) in matches(#"\b[A-Z]{1,3}-(\d{4,8})\b"#, in: text) {
            candidates.append((groups[1], position))
        }
        // "123 456" or "123-456".
        for (groups, position) in matches(#"(?<![\d.,:/])(\d{3})[ -](\d{3})(?![\d:/%]|[.,]\d)"#, in: text) {
            candidates.append((groups[1] + groups[2], position))
        }
        // A plain 4 to 8 digit number, not part of an amount, date, time or longer
        // number. A full stop or comma after it only counts when a digit follows.
        for (groups, position) in matches(#"(?<![\d.,:/\-])\d{4,8}(?![\d:/%]|[.,]\d)"#, in: text) {
            let digits = groups[0]
            if isAmount(beforeOffset: position, in: text) { continue }
            if isReference(beforeOffset: position, in: text) { continue }
            if digits.count == 4, let year = Int(digits), (1950...2099).contains(year) { continue }
            candidates.append((digits, position))
        }

        // The candidate nearest a keyword wins; ties go to the earlier one.
        func distance(_ candidate: (code: String, position: Int)) -> Int {
            keywordSpans.map { span in
                candidate.position >= span.upperBound
                    ? candidate.position - span.upperBound
                    : span.lowerBound - candidate.position
            }.min() ?? .max
        }
        return candidates
            .min { lhs, rhs in
                let left = distance(lhs), right = distance(rhs)
                return left == right ? lhs.position < rhs.position : left < right
            }?
            .code
    }

    /// Whether the number names a card or account, as in "card ending 1234"
    /// or "A/c XX5678", rather than being a code.
    private static func isReference(beforeOffset offset: Int, in text: String) -> Bool {
        let prefix = text.prefix(offset).suffix(14).lowercased()
            .trimmingCharacters(in: .whitespaces)
        return ["ending", "ending in", "ending with", "ends with", "ends in", "a/c", "a/c no", "a/c no.",
                "acct", "account", "account no", "account no.", "card", "card no", "card no.",
                "xx", "x", "*", "ref", "ref no", "ref no.", "ref."]
            .contains { prefix.hasSuffix($0) }
    }

    /// Each match's capture groups (0 is the whole match) and character offset.
    private static func matches(_ pattern: String, in text: String) -> [(groups: [String], position: Int)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : nsText.substring(with: range)
            }
            guard let range = Range(match.range, in: text) else { return nil }
            return (groups, text.distance(from: text.startIndex, to: range.lowerBound))
        }
    }

    /// Whether a currency comes just before the number, as in "Rs 1299" or "₹ 5000".
    private static func isAmount(beforeOffset offset: Int, in text: String) -> Bool {
        let prefix = text.prefix(offset).suffix(5).lowercased()
            .trimmingCharacters(in: .whitespaces)
        return ["rs", "rs.", "inr", "₹", "$", "usd", "eur", "€", "£", "gbp"].contains { prefix.hasSuffix($0) }
    }
}
