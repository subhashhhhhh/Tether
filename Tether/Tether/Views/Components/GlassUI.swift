//
//  GlassUI.swift
//  Tether
//
//  Sleek glassmorphism and modern system material UI components for Tether.
//  Targeting macOS design system with full accessibility and dark/light support.
//

import SwiftUI
import AppKit

// MARK: - Glass Button View

public struct GlassButtonView: View {
    public var label: String?
    public var systemImage: String?
    public var iconOnly: Bool = false
    public var size: ControlSize = .regular
    public var isProminent: Bool = false
    public var circleSize: CGFloat? = nil
    public var fixedIconSize: CGFloat? = nil
    public var helpText: String? = nil
    public var action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        label: String? = nil,
        systemImage: String? = nil,
        iconOnly: Bool = false,
        size: ControlSize = .regular,
        isProminent: Bool = false,
        circleSize: CGFloat? = nil,
        fixedIconSize: CGFloat? = nil,
        helpText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.iconOnly = iconOnly
        self.size = size
        self.isProminent = isProminent
        self.circleSize = circleSize
        self.fixedIconSize = fixedIconSize
        self.helpText = helpText
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            contentView
        }
        .buttonStyle(.plain)
        .contentShape(shape)
        .background(backgroundView)
        .overlay(borderView)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(helpText ?? label ?? "")
        .accessibilityLabel(label ?? helpText ?? "Button")
    }

    @ViewBuilder
    private var contentView: some View {
        if let circle = circleSize {
            ZStack {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: fixedIconSize ?? (circle * 0.42), weight: .medium))
                        .foregroundColor(foregroundColor)
                } else if let label {
                    Text(label)
                        .font(.system(size: fixedIconSize ?? 13, weight: .semibold))
                        .foregroundColor(foregroundColor)
                }
            }
            .frame(width: circle, height: circle)
        } else if iconOnly, let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: fixedIconSize ?? 14, weight: .medium))
                .foregroundColor(foregroundColor)
                .padding(paddingForSize)
        } else {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: fixedIconSize ?? 13, weight: .medium))
                }
                if let label {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundColor(foregroundColor)
            .padding(paddingForSize)
        }
    }

    private var foregroundColor: Color {
        if isProminent {
            return .white
        }
        return isHovered ? .primary : .primary.opacity(0.85)
    }

    private var paddingForSize: EdgeInsets {
        switch size {
        case .mini:
            return EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
        case .small:
            return EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
        case .regular:
            return EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11)
        case .large, .extraLarge:
            return EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
        @unknown default:
            return EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11)
        }
    }

    private var shape: AnyShape {
        if circleSize != nil {
            return AnyShape(Circle())
        } else {
            return AnyShape(RoundedRectangle(cornerRadius: cornerRadiusForSize, style: .continuous))
        }
    }

    private var cornerRadiusForSize: CGFloat {
        switch size {
        case .mini: return 6
        case .small: return 8
        case .regular: return 10
        case .large, .extraLarge: return 12
        @unknown default: return 10
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if circleSize != nil {
            Circle()
                .fill(isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial))
                .opacity(isHovered ? 1.0 : 0.9)
        } else {
            RoundedRectangle(cornerRadius: cornerRadiusForSize, style: .continuous)
                .fill(isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial))
                .opacity(isHovered ? 1.0 : 0.9)
        }
    }

    @ViewBuilder
    private var borderView: some View {
        if circleSize != nil {
            Circle()
                .stroke(Color.white.opacity(isHovered ? 0.22 : 0.10), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: cornerRadiusForSize, style: .continuous)
                .stroke(Color.white.opacity(isHovered ? 0.22 : 0.10), lineWidth: 1)
        }
    }
}

// MARK: - Glass Card Container

public struct GlassCard<Content: View>: View {
    public var cornerRadius: CGFloat
    public var paddingAmount: CGFloat
    public var content: () -> Content

    public init(
        cornerRadius: CGFloat = 16,
        paddingAmount: CGFloat = 14,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.paddingAmount = paddingAmount
        self.content = content
    }

    public var body: some View {
        content()
            .padding(paddingAmount)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Connection Status Pill

public struct ConnectionStatusPill: View {
    public var status: DeviceStatus
    public var networkType: String?
    public var isInteractive: Bool = false
    public var onAction: (() -> Void)? = nil

    @State private var isHovered: Bool = false

    public init(
        status: DeviceStatus,
        networkType: String? = nil,
        isInteractive: Bool = false,
        onAction: (() -> Void)? = nil
    ) {
        self.status = status
        self.networkType = networkType
        self.isInteractive = isInteractive
        self.onAction = onAction
    }

    public var body: some View {
        HStack(spacing: 6) {
            // Pulsing status dot
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
                .shadow(color: status.color.opacity(status == .connected ? 0.6 : 0), radius: 3)

            // Network icon
            Image(systemName: networkIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            // Status label
            Text(statusLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary.opacity(0.88))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(isHovered ? 0.25 : 0.12), lineWidth: 1)
        )
        .scaleEffect(isHovered && isInteractive ? 1.04 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            if isInteractive {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onAction?()
        }
    }

    private var networkIcon: String {
        switch status {
        case .connected:
            if let net = networkType?.lowercased(), net.contains("cellular") || net.contains("lte") || net.contains("5g") {
                return "antenna.radiowaves.left.and.right"
            }
            return "wifi"
        case .available:
            return "antenna.radiowaves.left.and.right"
        case .offline:
            return "wifi.slash"
        }
    }

    private var statusLabel: String {
        switch status {
        case .connected:
            return networkType ?? "Connected"
        case .available:
            return "Ready to Pair"
        case .offline:
            return "Offline"
        }
    }
}
