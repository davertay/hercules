import SwiftUI

/// Cubic-bezier dependency edge between two nodes in the rect-based DAG layout. Works in absolute
/// coordinates: `from` is the source rect's bottom-edge midpoint, `to` the destination's top-edge
/// midpoint, both supplied by `EdgesLayer` after resolving `Anchor<CGRect>` preferences against its
/// `GeometryProxy`. `path(in:)` ignores the `rect` parameter and emits the curve in the parent's
/// coordinate space.
///
/// The bezier exits the source's bottom flat edge going down, swings toward the destination's column
/// at the row midline, and enters the destination's top flat edge — the canonical layered-DAG S-curve.
/// It terminates `arrowheadLength` short of `to` so the `ArrowheadShape` triangle covers the end-cap.
///
/// The `TicketGraph`/`IssueGraph` layered layout guarantees a child's `y` is strictly greater than
/// every dependency's, so every edge runs downward — same-row or upward edges aren't producible, and
/// the shape doesn't handle them.
struct EdgeShape: Shape {
    /// Source rect's bottom-edge midpoint, in the parent `GeometryProxy`'s coordinate space.
    let from: CGPoint

    /// Destination rect's top-edge midpoint. The bezier terminates `arrowheadLength` short of this so
    /// the matching `ArrowheadShape` covers the end-cap.
    let to: CGPoint

    /// Length of the arrowhead the parent draws separately at `to`; the bezier endpoint is offset up
    /// by this amount so the two shapes meet cleanly at the arrowhead's base.
    let arrowheadLength: CGFloat

    func path(in _: CGRect) -> Path {
        let bezierEnd = CGPoint(x: to.x, y: to.y - arrowheadLength)
        let midY = (from.y + bezierEnd.y) / 2
        var path = Path()
        path.move(to: from)
        path.addCurve(
            to: bezierEnd,
            control1: CGPoint(x: from.x, y: midY),
            control2: CGPoint(x: bezierEnd.x, y: midY)
        )
        return path
    }
}

/// Filled isoceles triangle at the destination end of an edge. Tip sits at the destination rect's
/// top-edge midpoint (`to`), pointing down into the rect; base sits `length` above the tip. Drawn
/// separately from `EdgeShape` so the triangle can be `.fill`'d while the bezier is `.stroke`'d; the
/// shared `to`/`length` make the bezier's endpoint coincide with the triangle's base. `length` doubles
/// as the base width (square aspect — the classic graphviz/dagre arrowhead ratio).
struct ArrowheadShape: Shape {
    /// Tip of the arrowhead — the destination rect's top-edge midpoint.
    let to: CGPoint

    /// Distance from the tip to the base; also the base width (square aspect).
    let length: CGFloat

    func path(in _: CGRect) -> Path {
        let baseY = to.y - length
        let halfBase = length / 2
        var path = Path()
        path.move(to: to)
        path.addLine(to: CGPoint(x: to.x - halfBase, y: baseY))
        path.addLine(to: CGPoint(x: to.x + halfBase, y: baseY))
        path.closeSubpath()
        return path
    }
}

#if DEBUG

#Preview("Single edge") {
    ZStack {
        Color(white: 0.98)
        EdgeShape(
            from: CGPoint(x: 80, y: 40),
            to: CGPoint(x: 220, y: 200),
            arrowheadLength: 8
        )
        .stroke(Color.gray, lineWidth: 2)
        ArrowheadShape(
            to: CGPoint(x: 220, y: 200),
            length: 8
        )
        .fill(Color.gray)
    }
    .frame(width: 300, height: 240)
}

#endif
