import SwiftUI

/// Background layer of `DAGGraphView` that draws every dependency edge as a stroked cubic bezier
/// topped by a filled triangle arrowhead, between the actual rendered frames of the source and
/// destination node cards.
///
/// **How geometry flows.** Each node card attaches an `Anchor<CGRect>` for its bounds via
/// `.anchorPreference(key: NodeBoundsKey.self, value: .bounds, ...)` in `DAGGraphView`'s body. SwiftUI
/// merges those into a single `[Int: Anchor<CGRect>]` (keyed by Issue number) through the
/// `NodeBoundsKey` preference. `DAGGraphView` reads the merged dictionary via
/// `.backgroundPreferenceValue` and constructs this layer, which resolves each anchor to a concrete
/// `CGRect` via `proxy[anchor]`. The edge positions therefore track the real rendered frames, so a
/// content-driven reflow updates the edges on the next layout pass with no grid math.
///
/// Drawn in the background (not overlay) so any fractional sliver of the bezier at the endpoint is
/// occluded by the node fill. Edges render in `palette.pending` — a flat structural-connector grey
/// that doesn't compete with the status-coloured node borders.
struct EdgesLayer: View {
    /// All `(from → to)` dependency pairs to draw, by Issue number.
    let edges: [DependencyEdge]

    /// Bounds anchors for every node currently in the layout, keyed by Issue number.
    let anchors: [Int: Anchor<CGRect>]

    let metrics: DAGGraphMetrics
    let palette: StatusPalette

    var body: some View {
        GeometryReader { proxy in
            // Square-aspect arrowhead per ArrowheadShape's contract — length == base width.
            let arrowheadLength = metrics.edgeStrokeWidth * 4
            let edgeColor = palette.pending

            ZStack {
                ForEach(edges) { edge in
                    if let fromAnchor = anchors[edge.from],
                       let toAnchor = anchors[edge.to] {
                        let fromRect = proxy[fromAnchor]
                        let toRect = proxy[toAnchor]
                        // Source exits its bottom-edge midpoint; destination enters its top-edge midpoint.
                        let fromPoint = CGPoint(x: fromRect.midX, y: fromRect.maxY)
                        let toPoint = CGPoint(x: toRect.midX, y: toRect.minY)

                        EdgeShape(
                            from: fromPoint,
                            to: toPoint,
                            arrowheadLength: arrowheadLength
                        )
                        .stroke(edgeColor, lineWidth: metrics.edgeStrokeWidth)

                        ArrowheadShape(
                            to: toPoint,
                            length: arrowheadLength
                        )
                        .fill(edgeColor)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// One dependency edge to render, identified by its `(from, to)` Issue-number pair so `ForEach` can
/// stably diff the edge list across body re-evaluations.
struct DependencyEdge: Identifiable, Hashable {
    let from: Int
    let to: Int

    var id: String { "\(from)->\(to)" }
}
