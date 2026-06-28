import IssueGraph
import SwiftUI

/// Rect-based DAG view: a `VStack` of `HStack` rows of `NodeView` cards (one row per `LayoutNode.y`)
/// over a background `EdgesLayer`. Cards publish their frames as `NodeBoundsKey` anchors that
/// `EdgesLayer` resolves to draw edges — no grid math, edges track the real rendered frames across
/// reflows. A foundation view with no concept of any Phase; feature surfaces embed it.
public struct DAGGraphView<NodeContent: View>: View {
    let layoutNodes: [IssueGraph.LayoutNode]
    let nodesByNumber: [Int: DAGNode]
    let metrics: DAGGraphMetrics
    let palette: StatusPalette
    let selectedID: Int?
    let onSelectNode: ((Int) -> Void)?
    let onContentSizeChange: ((CGSize) -> Void)?
    let nodeContent: (DAGNode, _ isSelected: Bool) -> NodeContent

    public init(
        layoutNodes: [IssueGraph.LayoutNode],
        nodesByNumber: [Int: DAGNode],
        metrics: DAGGraphMetrics,
        palette: StatusPalette,
        selectedID: Int? = nil,
        onSelectNode: ((Int) -> Void)? = nil,
        onContentSizeChange: ((CGSize) -> Void)? = nil,
        @ViewBuilder nodeContent: @escaping (DAGNode, _ isSelected: Bool) -> NodeContent
    ) {
        self.layoutNodes = layoutNodes
        self.nodesByNumber = nodesByNumber
        self.metrics = metrics
        self.palette = palette
        self.selectedID = selectedID
        self.onSelectNode = onSelectNode
        self.onContentSizeChange = onContentSizeChange
        self.nodeContent = nodeContent
    }

    /// Convenience initializer defaulting each card to the built-in `NodeView`, so callers that don't need
    /// custom card content (previews, the preview harness) keep their existing call site unchanged.
    public init(
        layoutNodes: [IssueGraph.LayoutNode],
        nodesByNumber: [Int: DAGNode],
        metrics: DAGGraphMetrics,
        palette: StatusPalette,
        selectedID: Int? = nil,
        onSelectNode: ((Int) -> Void)? = nil
    ) where NodeContent == NodeView {
        self.init(
            layoutNodes: layoutNodes,
            nodesByNumber: nodesByNumber,
            metrics: metrics,
            palette: palette,
            selectedID: selectedID,
            onSelectNode: onSelectNode
        ) { node, isSelected in
            NodeView(node: node, metrics: metrics, palette: palette, isSelected: isSelected)
        }
    }

    private var rows: [Row] {
        let grouped = Dictionary(grouping: layoutNodes, by: \.y)
        return grouped.keys.sorted().map { y in
            let sorted = grouped[y, default: []].sorted { $0.x < $1.x }
            let nodes = sorted.compactMap { nodesByNumber[$0.id] }
            return Row(y: y, nodes: nodes)
        }
    }

    /// Sorted by `(to, from)` for stable `ForEach` diffing.
    private var edges: [DependencyEdge] {
        nodesByNumber.values
            .flatMap { node in
                node.dependencies.map { DependencyEdge(from: $0, to: node.number) }
            }
            .sorted { lhs, rhs in
                if lhs.to != rhs.to { return lhs.to < rhs.to }
                return lhs.from < rhs.from
            }
    }

    public var body: some View {
        // Anchor under-sized content to the top. By default macOS's `ScrollView` rests content smaller
        // than the viewport in the *centre* while hit-testing keeps the top-aligned layout frames — so
        // the graph both renders mis-positioned and mis-routes taps to the wrong node. Anchoring the rest
        // position to `.top` realigns the rendered graph with its hit regions.
        ScrollView([.horizontal, .vertical]) {
            graphContent
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var graphContent: some View {
        VStack(spacing: metrics.rowGap) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: metrics.columnGap) {
                    ForEach(row.nodes) { node in
                        nodeContent(node, node.number == selectedID)
                        .contentShape(
                            RoundedRectangle(cornerRadius: metrics.nodeCornerRadius)
                        )
                        .onTapGesture {
                            onSelectNode?(node.number)
                        }
                        .anchorPreference(
                            key: NodeBoundsKey.self,
                            value: .bounds
                        ) { anchor in
                            [node.number: anchor]
                        }
                    }
                }
            }
        }
        .padding(metrics.outerPadding)
        .backgroundPreferenceValue(NodeBoundsKey.self) { anchors in
            EdgesLayer(
                edges: edges,
                anchors: anchors,
                metrics: metrics,
                palette: palette
            )
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                    onContentSizeChange?(size)
                }
            }
        }
    }
}

/// `id` is the `y` level so `ForEach` stably diffs rows across updates.
private struct Row: Identifiable {
    let y: Int
    let nodes: [DAGNode]

    var id: Int { y }
}

/// Aggregates per-`NodeView` bounds anchors (keyed by Issue number) for `EdgesLayer`. The reduce
/// prefers the latest write, which only matters transiently mid-reflow.
struct NodeBoundsKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [Int: Anchor<CGRect>],
        nextValue: () -> [Int: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

#if DEBUG

#Preview("Mixed-status DAG") {
    let nodes: [DAGNode] = [
        DAGNode(number: 1, title: "Foundations", status: .done, dependencies: []),
        DAGNode(number: 2, title: "Public types", status: .done, dependencies: []),
        DAGNode(number: 3, title: "First tracer", status: .inProgress, dependencies: [1]),
        DAGNode(number: 4, title: "Conflict path", status: .ready, dependencies: [1, 2]),
        DAGNode(number: 5, title: "Recovery branch", status: .pending, dependencies: [3]),
        DAGNode(number: 6, title: "Wire end-to-end", status: .failed, dependencies: [3, 4]),
        DAGNode(number: 7, title: "Cancelled spike", status: .skipped, dependencies: [2]),
    ]
    let layoutNodes = IssueGraph.layeredLayout(nodes)
    let nodesByNumber = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })

    return DAGGraphView(
        layoutNodes: layoutNodes,
        nodesByNumber: nodesByNumber,
        metrics: .default,
        palette: .default
    )
    .frame(minWidth: 800, minHeight: 600)
}

#Preview("Linear two-node DAG") {
    let nodes: [DAGNode] = [
        DAGNode(number: 1, title: "Add greeting endpoint", status: .done, dependencies: []),
        DAGNode(number: 2, title: "Render greeting card", status: .ready, dependencies: [1]),
    ]
    let layoutNodes = IssueGraph.layeredLayout(nodes)
    let nodesByNumber = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })

    return DAGGraphView(
        layoutNodes: layoutNodes,
        nodesByNumber: nodesByNumber,
        metrics: .default,
        palette: .default
    )
    .frame(minWidth: 600, minHeight: 400)
}

#endif
