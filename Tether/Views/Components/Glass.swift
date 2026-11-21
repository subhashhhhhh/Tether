//
//  Glass.swift
//  Tether
//
//  Tether's surface language: Liquid Glass on macOS 26, the system's
//  translucent materials on macOS 15, same shapes and spacing on both.
//  Glass is for things that float over content: the popover's panels, the
//  call card, buttons. Content in the main window sits on plain cards.
//

import SwiftUI

enum GlassMetrics {
    static let panelRadius: CGFloat = 20
    static let cardRadius: CGFloat = 40
}

extension View {
    /// A floating panel: Liquid Glass, or a thick material with a hairline edge.
    @ViewBuilder
    func glassPanel(radius: CGFloat = GlassMetrics.panelRadius) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: .rect(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    /// A card in the content layer. Liquid Glass belongs to controls and
    /// navigation, so content gets a quiet fill instead, like a grouped form.
    func contentCard(radius: CGFloat = 16) -> some View {
        background(Color(nsColor: .quaternarySystemFill), in: .rect(cornerRadius: radius, style: .continuous))
    }

    /// Something that floats over the top of a scroll view, which scrolls
    /// beneath it. An overlay with a matching content margin, not a safe
    /// area inset: the system extends the toolbar's band and its line over
    /// an inset, and what's wanted is nothing behind but the content.
    func floatingHeader<Header: View>(height: CGFloat, @ViewBuilder content: () -> Header) -> some View {
        contentMargins(.top, height, for: .scrollContent)
            .overlay(alignment: .top) { content() }
    }

    /// Put on the scroll view itself: no edge effect at the top, for a list
    /// whose rows should simply pass under a floating control.
    @ViewBuilder
    func noTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }

    /// A text field's capsule: glass on macOS 26, a soft fill before.
    /// `interactive` makes the glass respond to the pointer, for a capsule
    /// that is a button.
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            self
                .background(.quaternary.opacity(0.7), in: .capsule)
        }
    }

    /// A small text button: glass on macOS 26, bordered before.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Glass over imagery (the phone card), where the material should stay clear.
    @ViewBuilder
    func clearGlass(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// A round glass button with a symbol, and optionally a caption under it.
struct GlassCircleButton: View {
    let title: String
    let systemImage: String
    var showsTitle = true
    var size: CGFloat = 44
    var isProminent = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            button
            if showsTitle {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .help(title)
    }

    @ViewBuilder
    private var button: some View {
        // Full contrast: a dimmed glyph and caption read as a disabled control.
        let label = Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .medium))
            .frame(width: size, height: size)
            .contentShape(.circle)
            .accessibilityLabel(title)

        if #available(macOS 26.0, *) {
            if isProminent {
                Button(action: action) { label }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
        } else {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(isProminent ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial), in: .circle)
                .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        }
    }
}

/// A bar floating over a scroll view. It has no background at rest: what
/// scrolls behind shows through untouched. While the pointer is over it,
/// what's behind blurs, fading out at the bar's inner edge so there is no line.
struct HoverBlurBar<Content: View>: View {
    let edge: VerticalEdge
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                            startPoint: edge == .top ? .top : .bottom,
                            endPoint: edge == .top ? .bottom : .top
                        )
                    }
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.18), value: isHovering)
    }
}

/// Glass controls that sit together share one container, so they render as
/// a set and can blend into each other.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// How a device is doing: its connection, battery or network. It's
/// information, not a control, so it's plain text with no capsule behind it.
struct StatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color = .green

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.callout)
    }
}

/// A section heading over a card.
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Pages

/// A device section laid out like the Overview: a scrolling column of
/// sections. The page's name is the toolbar's title and its actions are
/// toolbar buttons, so the column starts with content.
struct GlassPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A titled card, with an optional note under it.
struct GlassSection<Trailing: View, Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title) { trailing }
            VStack(spacing: 0) { content }
                .contentCard()
            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension View {
    /// Padding for a row inside a glass panel.
    func glassRow() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Entrance

private struct StaggeredEntrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(MotionPreference.key) private var tetherReduceMotion = false
    @State private var isShown = false

    private var reduceMotion: Bool { systemReduceMotion || tetherReduceMotion }

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : -8)
            .onAppear {
                guard !isShown else { return }
                if reduceMotion {
                    isShown = true
                } else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82).delay(Double(index) * 0.045)) {
                        isShown = true
                    }
                }
            }
    }
}

extension View {
    /// Fades and settles in after the ones before it, e.g. the popover's panels.
    func staggeredEntrance(_ index: Int) -> some View {
        modifier(StaggeredEntrance(index: index))
    }
}

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
