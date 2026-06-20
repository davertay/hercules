import IssueGraph
import SwiftUI

/// Top-level rect-based DAG view. Renders a Workflow's Issues as a layered grid of `NodeView` cards (a
/// `VStack` of `HStack`s, one row per `LayoutNode.y` level, ordered left-to-right by `LayoutNode.x`
/// within each row) with a background `EdgesLayer` drawing one cubic-bezier-and-arrowhead per
/// dependency between the cards' actual rendered frames.
///
/// **Geometry.** Each card attaches an `Anchor<CGRect>` via `.anchorPreference(key: NodeBoundsKey)`;
/// the merged `[Int: Anchor<CGRect>]` is read with `.backgroundPreferenceValue` and fed, with the
/// derived edge list, into `EdgesLayer`, which resolves anchors to frames against its `GeometryProxy`.
/// No grid math at the call site — edges track the real rendered frames across reflows.
///
/// **Scrolling.** The content sits in a both-axes `ScrollView` so a deep/wide DAG can be panned; the
/// inner `VStack`/`HStack` sizes itself naturally to the rendered bounds.
///
/// **Selection.** `selectedID` drives an accent halo on the matching node; taps fire `onSelectNode`
/// with the node's Issue number. The host owns the toggle/clear logic. Both default to nil so call
/// sites without an inspector compile unchanged.
///
/// **Module boundary.** A foundation view with no concept of "Execute" or "Allocate" — just `[DAGNode]`
/// + `[LayoutNode]` + a status palette. Feature surfaces own their own scaffolding and embed this.
public struct DAGGraphView: View {
    let layoutNodes: [IssueGraph.LayoutNode]
    let nodesByNumber: [Int: DAGNode]
    let metrics: DAGGraphMetrics
    let palette: StatusPalette
    let selectedID: Int?
    let onSelectNode: ((Int) -> Void)?

    public init(
        layoutNodes: [IssueGraph.LayoutNode],
        nodesByNumber: [Int: DAGNode],
        metrics: DAGGraphMetrics,
        palette: StatusPalette,
        selectedID: Int? = nil,
        onSelectNode: ((Int) -> Void)? = nil
    ) {
        self.layoutNodes = layoutNodes
        self.nodesByNumber = nodesByNumber
        self.metrics = metrics
        self.palette = palette
        self.selectedID = selectedID
        self.onSelectNode = onSelectNode
    }

    /// Nodes grouped by `y` (row level), each row's nodes in `LayoutNode.x`-ascending order.
    private var rows: [Row] {
        let grouped = Dictionary(grouping: layoutNodes, by: \.y)
        return grouped.keys.sorted().map { y in
            let sorted = grouped[y, default: []].sorted { $0.x < $1.x }
            let nodes = sorted.compactMap { nodesByNumber[$0.id] }
            return Row(y: y, nodes: nodes)
        }
    }

    /// All `(dep → node)` pairs across the graph, sorted by `(to, from)` for stable `ForEach` diffing.
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
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: metrics.rowGap) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: metrics.columnGap) {
                        ForEach(row.nodes) { node in
                            NodeView(
                                node: node,
                                metrics: metrics,
                                palette: palette,
                                isSelected: node.number == selectedID
                            )
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row in the layered layout — a single `LayoutNode.y` level, holding the nodes at that level in
/// `x`-ascending order. `id` is the `y` level so `ForEach` stably diffs rows across updates.
private struct Row: Identifiable {
    let y: Int
    let nodes: [DAGNode]

    var id: Int { y }
}

/// PreferenceKey aggregating per-`NodeView` bounds anchors into a single `[Int: Anchor<CGRect>]`
/// (keyed by Issue number) for `EdgesLayer`. Anchors are coordinate-space-agnostic — SwiftUI resolves
/// them to a `CGRect` against whatever `GeometryProxy` reads them, regardless of where the writer sat.
/// The reduce prefers the latest write, which only matters transiently mid-reflow.
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
