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

    /// A round control's glass, at exactly the view's size.
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(.regularMaterial, in: .circle)
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

/// The fill behind one row of a group in a list, so a run of rows reads as
/// one card: rounded at the top of the first and the bottom of the last. A
/// list is used where rows swipe; this keeps the grouping a card would give.
struct GroupCardBackground: View {
    let isFirst: Bool
    let isLast: Bool
    /// The column the card keeps to, and its margin in a narrow window.
    var maxWidth: CGFloat = 680
    var margin: CGFloat = 16

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? 16 : 0, bottomLeadingRadius: isLast ? 16 : 0,
            bottomTrailingRadius: isLast ? 16 : 0, topTrailingRadius: isFirst ? 16 : 0,
            style: .continuous
        )
        .fill(Color(nsColor: .quaternarySystemFill))
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, margin)
        .frame(maxWidth: .infinity)
    }
}

/// A bar floating over a scroll view. It has no background at rest: what
/// scrolls behind shows through untouched. While the pointer is over it, it
/// takes the bar material with a hairline at its inner edge, as Messages'
/// header does: a clean band, not a fade.
struct HoverBlurBar<Content: View>: View {
    let edge: VerticalEdge
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .background {
                Rectangle()
                    .fill(.bar)
                    .overlay(alignment: edge == .top ? .bottom : .top) { Divider() }
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.18), value: isHovering)
    }
}

extension View {
    /// A list of cards kept to a readable width in a wide window. A list
    /// draws a row's swipe buttons at the row's edge, so the list itself is
    /// narrowed, which keeps Dismiss right behind a card. A swiped card can
    /// still slide past the list's edge, and the list's own scroll bar,
    /// which would sit mid-window, is hidden.
    func readableCardList(maxWidth: CGFloat = 760) -> some View {
        scrollClipDisabled()
            .scrollIndicators(.hidden)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
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
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var isShown = false


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
