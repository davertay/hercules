import SwiftUI

/// Background layer of `DAGGraphView` drawing each dependency edge as a stroked bezier plus arrowhead.
/// Resolves each node's `NodeBoundsKey` anchor to a `CGRect` via `proxy[anchor]`, so edges track the
/// real rendered frames across reflows. Drawn in the background (not overlay) so the bezier's endpoint
/// sliver is occluded by the node fill.
struct EdgesLayer: View {
    let edges: [DependencyEdge]

    let anchors: [Int: Anchor<CGRect>]

    let metrics: DAGGraphMetrics

    var body: some View {
        GeometryReader { proxy in
            // Square-aspect arrowhead per ArrowheadShape's contract — length == base width.
            let arrowheadLength = metrics.edgeStrokeWidth * 4
            let edgeColor = Color.secondary

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

struct DependencyEdge: Identifiable, Hashable {
    let from: Int
    let to: Int

    var id: String { "\(from)->\(to)" }
}
