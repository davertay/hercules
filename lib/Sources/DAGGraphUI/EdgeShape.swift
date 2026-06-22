import SwiftUI

/// Cubic-bezier dependency edge in absolute coordinates, so `path(in:)` ignores its `rect` and emits
/// the curve in the parent's coordinate space. The layered layout guarantees a child's `y` exceeds
/// every dependency's, so every edge runs downward — upward/same-row edges aren't handled.
struct EdgeShape: Shape {
    /// Source rect's bottom-edge midpoint, in the parent `GeometryProxy`'s coordinate space.
    let from: CGPoint

    /// Destination rect's top-edge midpoint.
    let to: CGPoint

    /// The bezier endpoint is offset up by this so it meets the `ArrowheadShape`'s base cleanly.
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

/// Filled arrowhead triangle at an edge's destination. Drawn separately from `EdgeShape` so it can be
/// `.fill`'d while the bezier is `.stroke`'d; the shared `to`/`length` make their ends coincide.
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
