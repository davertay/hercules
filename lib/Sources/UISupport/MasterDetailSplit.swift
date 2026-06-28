import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// A master/detail split whose divider position is *derived from window width* rather than dragged.
///
/// While the window is too narrow to show the master at its ideal width, the two panes share the space
/// by a fixed tension ratio (60/40 by default) and the master scrolls. Once the window is wide enough to
/// show the master without scrolling, the master pins to its ideal width and every extra point flows to
/// the detail pane — up to its maximum, after which the surplus becomes master canvas. The effect: drag
/// the window edge out and the graph snaps fully into view while the inspector grows to your liking. The
/// detail width is always clamped to `[detailMinWidth, detailMaxWidth]`.
///
/// An "auto-fit" toolbar button resizes the host window so the master is fully visible — its ideal width
/// with the detail at its ideal width, and (when `masterContentHeight` is known) tall enough to show the
/// whole master without vertical scrolling. The target is clamped to the usable screen, so an oversized
/// master leaves the window scrolling rather than spilling off the desktop.
public struct MasterDetailSplit<Master: View, Detail: View>: View {
    let masterIdealWidth: CGFloat
    let masterContentHeight: CGFloat?
    let detailMinWidth: CGFloat
    let detailIdealWidth: CGFloat
    let detailMaxWidth: CGFloat
    let detailTensionFraction: CGFloat
    let master: Master
    let detail: Detail

    private static var dividerWidth: CGFloat { 1 }

    #if canImport(AppKit)
    @State private var hostWindow: NSWindow?
    /// The split's own rendered width. The split is usually *not* the whole window — a sidebar (and other
    /// chrome) sits outside it — so auto-fit measures `windowContentWidth − splitWidth` to learn how much
    /// to add on top of the split's target, otherwise the sidebar eats into the budget and the master
    /// comes up short.
    @State private var splitWidth: CGFloat = 0
    /// The split's rendered height ≈ the master pane's viewport height, used to decide whether the master
    /// overflows vertically (and so needs room reserved for a vertical scroller).
    @State private var splitHeight: CGFloat = 0
    #endif

    /// Whether the master content is taller than its viewport, so a vertical scroller is showing. Only
    /// then does the scroller's gutter need reserving — otherwise reserving it would leave a dead strip.
    /// A `nil` `masterContentHeight` (caller doesn't report it) is treated as non-overflowing.
    private var masterScrollsVertically: Bool {
        #if canImport(AppKit)
        guard let contentHeight = masterContentHeight, splitHeight > 0 else { return false }
        return contentHeight > splitHeight
        #else
        return false
        #endif
    }

    /// Width reserved beside the master so its vertical scroller never forces a *horizontal* scroller.
    ///
    /// It's two scroller-widths, not one. A `ScrollView([.horizontal, .vertical])` whose content is near
    /// the width boundary settles into a "both bars showing" state: the vertical scroller eats width
    /// (→ horizontal bar appears), the horizontal bar eats height (→ vertical bar stays). Escaping that
    /// needs roughly two scroller-widths of horizontal slack. Deriving it from `scrollerWidth` keeps it
    /// tracking the platform (e.g. Accessibility's larger scrollers) instead of a hard-coded constant.
    private var scrollerGutterWidth: CGFloat {
        #if canImport(AppKit)
        2 * NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        #else
        0
        #endif
    }

    /// Always reserve space for the scroll gutter
    private var masterScrollbarInset: CGFloat {
        scrollerGutterWidth
    }

    /// `masterIdealWidth` plus room for the master's vertical scroller — the width at which the master
    /// renders without a *horizontal* scroller. The layout pins the master here and auto-fit targets it.
    private var effectiveMasterIdeal: CGFloat { masterIdealWidth + masterScrollbarInset }

    /// - Parameters:
    ///   - masterIdealWidth: The width at which the master content is fully visible without scrolling.
    ///   - masterContentHeight: The master's rendered content height, if known; lets the split reserve a
    ///     vertical-scroller gutter only while the master actually overflows vertically.
    ///   - detailMinWidth/detailMaxWidth: Hard bounds the detail pane is always clamped to.
    ///   - detailIdealWidth: The detail width the auto-fit button targets.
    ///   - detailTensionFraction: The detail's share while the window is too narrow to fit the master.
    public init(
        masterIdealWidth: CGFloat,
        masterContentHeight: CGFloat? = nil,
        detailMinWidth: CGFloat = 320,
        detailIdealWidth: CGFloat = 520,
        detailMaxWidth: CGFloat = 760,
        detailTensionFraction: CGFloat = 0.4,
        @ViewBuilder master: () -> Master,
        @ViewBuilder detail: () -> Detail
    ) {
        self.masterIdealWidth = masterIdealWidth
        self.masterContentHeight = masterContentHeight
        self.detailMinWidth = detailMinWidth
        self.detailIdealWidth = detailIdealWidth
        self.detailMaxWidth = detailMaxWidth
        self.detailTensionFraction = detailTensionFraction
        self.master = master()
        self.detail = detail()
    }

    public var body: some View {
        MasterDetailLayout(
            masterIdealWidth: effectiveMasterIdeal,
            detailMinWidth: detailMinWidth,
            detailMaxWidth: detailMaxWidth,
            detailTensionFraction: detailTensionFraction,
            dividerWidth: Self.dividerWidth
        ) {
            master
            Rectangle()
                .fill(.separator)
                .frame(width: Self.dividerWidth)
            detail
        }
        #if canImport(AppKit)
        .background(WindowAccessor { hostWindow = $0 })
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                    splitWidth = size.width
                    splitHeight = size.height
                }
            }
        )
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: autoFit) {
                    Label("Fit Window", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Resize the window so the graph fits and the inspector sits at its ideal width")
            }
        }
        #endif
    }

    #if canImport(AppKit)
    private func autoFit() {
        guard let window = hostWindow else { return }

        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        // The split rarely fills the window: a sidebar sits beside it (horizontal chrome) and a banner can
        // sit above it (vertical chrome). Window borders/titlebar are the frame-vs-content insets. Carry
        // all of these over so the *split* lands at its target rather than the window.
        let frameInsetWidth = frame.width - content.width
        let frameInsetHeight = frame.height - content.height
        let horizontalChrome = splitWidth > 0 ? max(0, content.width - splitWidth) : 0
        let verticalChrome = splitHeight > 0 ? max(0, content.height - splitHeight) : 0

        // Never grow past the usable desktop (excludes menu bar and Dock); the split scrolls if clamped.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let maxSplitWidth = visible.width - frameInsetWidth - horizontalChrome
        let maxSplitHeight = visible.height - frameInsetHeight - verticalChrome

        // Height: show the whole graph (plus a hair so its own bottom edge clears), clamped to the screen.
        // If the caller doesn't report a content height, leave the height untouched.
        let contentHeight = masterContentHeight ?? 0
        let targetSplitHeight = contentHeight > 0 ? min(contentHeight + 2, maxSplitHeight) : splitHeight

        // Width: master ideal, plus the scroller gutter. The detail must be at least its width at the
        // tension→leftover crossover (`f/(1−f)·masterIdeal`) or the layout's tension share would starve
        // the master; clamp to bounds.
        let masterTarget = masterIdealWidth + scrollerGutterWidth
        let crossoverDetail = detailTensionFraction / (1 - detailTensionFraction) * masterTarget
        let targetDetail = min(max(max(detailIdealWidth, crossoverDetail), detailMinWidth), detailMaxWidth)
        let targetSplitWidth = min(masterTarget + Self.dividerWidth + targetDetail, maxSplitWidth)

        let newContentWidth = targetSplitWidth + horizontalChrome
        let newContentHeight = masterContentHeight == nil ? content.height : targetSplitHeight + verticalChrome

        // Anchor the window's top-left corner, then let AppKit nudge it fully onto the screen.
        var target = frame
        target.size = CGSize(width: newContentWidth + frameInsetWidth, height: newContentHeight + frameInsetHeight)
        target.origin.y = frame.maxY - target.height
        window.setFrame(window.constrainFrameRect(target, to: window.screen), display: true, animate: true)
    }
    #endif
}

/// Distributes a proposed width between the master (subview 0), divider (subview 1), and detail
/// (subview 2). The detail width is `clamp(max(tension·total, total − masterIdeal), [min, max])`: the
/// `max` of its tension share and "whatever's left once the master fits" meet continuously at the
/// crossover, so there's no jump as the window grows past the master's ideal width.
struct MasterDetailLayout: Layout {
    let masterIdealWidth: CGFloat
    let detailMinWidth: CGFloat
    let detailMaxWidth: CGFloat
    let detailTensionFraction: CGFloat
    let dividerWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (masterIdealWidth + dividerWidth + detailMaxWidth)
        let height = proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let total = max(0, bounds.width - dividerWidth)
        let detail = detailWidth(forTotal: total)
        let master = total - detail
        let height = bounds.height

        var x = bounds.minX
        for (subview, width) in zip(subviews, [master, dividerWidth, detail]) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: height)
            )
            x += width
        }
    }

    /// The detail pane's width for a given combined (master + detail) width.
    func detailWidth(forTotal total: CGFloat) -> CGFloat {
        let tensionShare = detailTensionFraction * total
        let leftoverOnceMasterFits = total - masterIdealWidth
        let raw = max(tensionShare, leftoverOnceMasterFits)
        return min(max(raw, detailMinWidth), detailMaxWidth)
    }
}

#if canImport(AppKit)
/// Resolves the `NSWindow` hosting this view so callers (e.g. the auto-fit button) can drive it. SwiftUI
/// has no native window-resize API, so this is the bridge.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
#endif
