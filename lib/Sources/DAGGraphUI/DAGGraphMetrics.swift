import CoreGraphics
import Foundation
import IssueGraph

/// Layout vocabulary for `DAGGraphView`, centralised so a re-skin is one edit.
public struct DAGGraphMetrics: Sendable {

    public let edgeStrokeWidth: CGFloat

    public let nodeWidth: CGFloat

    /// Floor; actual height is content-driven so mixed-length titles keep a uniform rhythm.
    public let nodeMinHeight: CGFloat

    /// Square enough that the four flat edges stay distinct as entry/exit surfaces for edges.
    public let nodeCornerRadius: CGFloat

    public let nodeBorderWidth: CGFloat

    public let rowGap: CGFloat

    public let columnGap: CGFloat

    public let outerPadding: CGFloat

    /// Cadence of the `.inProgress` pulse; perceived blink is half this (one fade out + in per cycle).
    public let pulseDuration: TimeInterval

    public init(
        edgeStrokeWidth: CGFloat = 2,
        nodeWidth: CGFloat = 168,
        nodeMinHeight: CGFloat = 64,
        nodeCornerRadius: CGFloat = 12,
        nodeBorderWidth: CGFloat = 3,
        rowGap: CGFloat = 56,
        columnGap: CGFloat = 24,
        outerPadding: CGFloat = 24,
        pulseDuration: TimeInterval = 1.2
    ) {
        self.edgeStrokeWidth = edgeStrokeWidth
        self.nodeWidth = nodeWidth
        self.nodeMinHeight = nodeMinHeight
        self.nodeCornerRadius = nodeCornerRadius
        self.nodeBorderWidth = nodeBorderWidth
        self.rowGap = rowGap
        self.columnGap = columnGap
        self.outerPadding = outerPadding
        self.pulseDuration = pulseDuration
    }

    public static let `default` = DAGGraphMetrics()

    /// The width at which `DAGGraphView` renders without horizontal scrolling: the widest row (its nodes
    /// laid out edge-to-edge with `columnGap` between them) plus `outerPadding` on both sides. Mirrors
    /// the row construction in `DAGGraphView` — uniform `nodeWidth` cards grouped by layout level (`y`).
    public func idealContentWidth(for layoutNodes: [IssueGraph.LayoutNode]) -> CGFloat {
        let widestRowCount = Dictionary(grouping: layoutNodes, by: \.y)
            .values
            .map(\.count)
            .max() ?? 0
        guard widestRowCount > 0 else { return 2 * outerPadding }
        let nodes = CGFloat(widestRowCount) * nodeWidth
        let gaps = CGFloat(widestRowCount - 1) * columnGap
        return nodes + gaps + 2 * outerPadding
    }
}
