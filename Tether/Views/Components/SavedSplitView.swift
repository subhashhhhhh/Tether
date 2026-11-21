//
//  SavedSplitView.swift
//  Tether
//
//  A two-pane split whose divider stays where it was left, across visits
//  and launches. SwiftUI's HSplitView can't do this: it opens a pane at its
//  minimum or maximum width and ignores any other. AppKit's split view saves
//  its divider in the user defaults under an autosave name.
//

import AppKit
import SwiftUI

struct SavedSplitView<Leading: View, Trailing: View>: NSViewControllerRepresentable {
    /// The defaults key the divider is saved under.
    let autosaveName: String
    /// The leading pane's allowed widths; it opens at the widest the first time.
    let leadingWidths: ClosedRange<CGFloat>
    let trailingMinimumWidth: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin

        let leadingItem = NSSplitViewItem(viewController: host(leading, context: context))
        leadingItem.minimumThickness = leadingWidths.lowerBound
        leadingItem.maximumThickness = leadingWidths.upperBound
        // Resizing the window changes the conversation, not the list.
        leadingItem.holdingPriority = .defaultLow + 10
        leadingItem.canCollapse = false

        let trailingItem = NSSplitViewItem(viewController: host(trailing, context: context))
        trailingItem.minimumThickness = trailingMinimumWidth
        trailingItem.holdingPriority = .defaultLow - 10
        trailingItem.canCollapse = false

        controller.addSplitViewItem(leadingItem)
        controller.addSplitViewItem(trailingItem)

        let isFirstTime = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosaveName)") == nil
        // Set after the panes exist, so the saved frames have something to restore.
        controller.splitView.autosaveName = autosaveName
        if isFirstTime {
            let width = leadingWidths.upperBound
            DispatchQueue.main.async { controller.splitView.setPosition(width, ofDividerAt: 0) }
        }
        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        let items = controller.splitViewItems
        guard items.count == 2 else { return }
        (items[0].viewController as? NSHostingController<AnyView>)?.rootView = rooted(leading, context: context)
        (items[1].viewController as? NSHostingController<AnyView>)?.rootView = rooted(trailing, context: context)
    }

    private func host(_ content: some View, context: Context) -> NSHostingController<AnyView> {
        let controller = NSHostingController(rootView: rooted(content, context: context))
        // The split view sizes the panes; the content mustn't push back.
        controller.sizingOptions = []
        controller.safeAreaRegions = .all
        return controller
    }

    /// Each pane is its own SwiftUI hierarchy, which doesn't inherit the
    /// environment, so the values the panes read are handed on.
    private func rooted(_ content: some View, context: Context) -> AnyView {
        AnyView(content
            .environment(\.isSidebarCollapsed, context.environment.isSidebarCollapsed)
            .tetherMotionPreference())
    }
}
