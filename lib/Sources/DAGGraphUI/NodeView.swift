import IssueGraph
import SwiftUI

/// One Issue node in `DAGGraphView`: a rounded-rect card with status-coloured border, `#number` badge,
/// and wrapping title. `.skipped` gets a diagonal slash; `.inProgress` alpha-pulses the border (only
/// opacity animates, not the colour, so the hue stays stable on wide-gamut displays).
struct NodeView: View {
    let node: DAGNode
    let metrics: DAGGraphMetrics
    let palette: StatusPalette
    let isSelected: Bool

    @State private var pulseActive: Bool = false

    init(
        node: DAGNode,
        metrics: DAGGraphMetrics,
        palette: StatusPalette,
        isSelected: Bool = false
    ) {
        self.node = node
        self.metrics = metrics
        self.palette = palette
        self.isSelected = isSelected
    }

    var body: some View {
        PulsingNodeView(
            color: palette.color(for: node.status),
            metrics: metrics,
            isPulsing: node.status == .inProgress,
            isSlashed: node.status == .skipped,
            isSelected: isSelected
        ) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("#\(node.number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .opacity(0.85)
                Text(node.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(palette.foregroundColor(for: node.status))
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(width: metrics.nodeWidth, alignment: .leading)
            .frame(minHeight: metrics.nodeMinHeight, alignment: .topLeading)
        }
    }
}

#if DEBUG

#Preview("All statuses") {
    @Previewable @State var isSelected: Bool = false

    let cases: [(IssueStatus, Int, String)] = [
        (.pending, 1, "Recovery branch"),
        (.ready, 2, "Conflict path"),
        (.inProgress, 3, "First tracer"),
        (.done, 4, "Foundations"),
        (.failed, 5, "Wire end-to-end"),
        (.skipped, 6, "Cancelled spike"),
    ]

    return VStack(alignment: .leading, spacing: Spacing.m) {
        Button("Toggle Selected") {
            isSelected.toggle()
        }
        ForEach(0..<cases.count, id: \.self) { i in
            let (status, number, title) = cases[i]
            HStack(alignment: .top, spacing: Spacing.m) {
                Text(String(describing: status))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                NodeView(
                    node: DAGNode(number: number, title: title, status: status, dependencies: []),
                    metrics: .default,
                    palette: .default,
                    isSelected: isSelected
                )
            }
        }
    }
    .padding(Spacing.l)
}

#Preview("Long title wraps") {
    NodeView(
        node: DAGNode(
            number: 42,
            title: "Migrate legacy workflow registry to typed identifiers across modules",
            status: .ready,
            dependencies: []
        ),
        metrics: .default,
        palette: .default
    )
    .padding(Spacing.l)
}

#endif
