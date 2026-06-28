import CoreGraphics
import Foundation
import IssueGraph

public struct DAGGraphMetrics: Sendable {

    public let edgeStrokeWidth: CGFloat

    public let nodeWidth: CGFloat

    public let nodeMinHeight: CGFloat

    public let nodeCornerRadius: CGFloat

    public let nodeBorderWidth: CGFloat

    public let rowGap: CGFloat

    public let columnGap: CGFloat

    public let outerPadding: CGFloat

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
