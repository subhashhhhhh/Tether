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

struct BatteryLabel: View {
    let percent: Int
    var isCharging: Bool = false

    private var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        Label {
            Text(percent, format: .percent.scale(1))
                .monospacedDigit()
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(percent <= 15 && !isCharging ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(percent) percent\(isCharging ? ", charging" : "")")
    }
}

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

    private var initials: String {
        let letters = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
        return letters.isEmpty ? "#" : String(letters).uppercased()
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

@MainActor
enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    /// Finder's icon for the file's type, looked up once per extension.
    static func image(for filename: String) -> NSImage {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = icon
        return icon
    }
}

enum FilePicker {
    /// Shows an open panel for choosing files to send. Returns an empty array on cancel.
    @MainActor
    static func chooseFiles(sendingTo deviceName: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(deviceName)"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

// MARK: - Fingerprint

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

// MARK: - Motion

enum MotionPreference {
    /// Settings › General › "Reduce motion". Off by default: Tether's few
    /// animations are short, and people who want them gone can say so here.
    static let key = "tether_reduce_motion"
}

private struct MotionPreferenceModifier: ViewModifier {
    @AppStorage(MotionPreference.key) private var tetherReduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// The system's Reduce Motion counts as well as Tether's own setting.
    private var reduceMotion: Bool { tetherReduceMotion || systemReduceMotion }

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }
}

extension View {
    /// Applies the user's Tether motion preference to this view and everything inside it.
    func tetherMotionPreference() -> some View {
        modifier(MotionPreferenceModifier())
    }
}
