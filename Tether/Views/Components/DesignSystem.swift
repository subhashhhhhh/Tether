//
//  DesignSystem.swift
//  Tether
//
//  The few pieces the system doesn't provide. Everything else is a stock
//  control, a grouped Form, or a sidebar List, so the app follows the user's
//  appearance, accent colour, text size and accessibility settings for free.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Devices

/// A device's SF Symbol at the surrounding text or sidebar size. Accent when
/// connected, secondary otherwise.
struct DeviceSymbol: View {
    let type: DeviceType
    var isActive: Bool = true

    var body: some View {
        Image(systemName: type.systemImageName)
            .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .accessibilityHidden(true)
    }
}

/// The large device symbol on full-page states (pairing, nearby, offline).
struct DeviceHero: View {
    let type: DeviceType
    var isActive: Bool = true

    var body: some View {
        Image(systemName: type.systemImageName)
            .resizable()
            .scaledToFit()
            .fontWeight(.light)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(height: 64)
            .accessibilityHidden(true)
    }
}

// MARK: - Status

// MARK: - Avatars

/// A contact monogram in one neutral style, as in Messages. Phone numbers get
/// a person silhouette since they have no meaningful initials.
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 32
    /// The contact's photo, shown instead of initials when there is one.
    var photo: Data? = nil
    /// A business's sender ID ("AD-HDFCBK-S"), not a person: initials made
    /// from it would suggest someone.
    var isSenderID = false

    private var image: NSImage? {
        photo.flatMap { ImageCache.image($0, maxPixels: Int(size * 2)) }
    }

    private var initials: String { Self.initials(of: name) ?? "#" }

    /// The first letter of up to two words, or nil when there are none.
    static func initials(of name: String) -> String? {
        let letters = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
        return letters.isEmpty ? nil : String(letters).uppercased()
    }

    private var isPhoneNumber: Bool {
        name.first?.isNumber == true || name.hasPrefix("+")
    }

    var body: some View {
        Circle()
            .fill(Color.gray.gradient)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else if isSenderID {
                    Image(systemName: "building.2.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.26)
                } else if isPhoneNumber {
                    Image(systemName: "person.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.26)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}

// MARK: - Search

/// The search pill Messages floats over its list: glass, tall enough to be
/// an easy target, with nothing behind it but the list.
struct SearchPill: View {
    @Binding var text: String
    var prompt = "Search"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 36)
        .glassCapsule()
    }
}

// MARK: - Files

// MARK: - Fingerprint

// MARK: - Motion

enum DeviceSymbols {
    /// A battery symbol for a level, with a bolt while charging.
    static func battery(_ percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
