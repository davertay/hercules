import Testing

@testable import IssueGraph

/// Tracers for `IssueGraph.layeredLayout(_:)`, ported from the prototype's per-discriminator
/// `LayeredLayout*Tests` and retyped from string ticket IDs to `Int` Issue numbers. Each case pins a
/// distinct axis of the layered-layout contract.
@Suite("IssueGraph.layeredLayout")
struct LayeredLayoutTests {

    /// One node per level at column 0 — pins the `y`-axis along a single path.
    @Test("Lays out a 5-node linear DAG as one node per level at column 0")
    func laysOutFiveNodeLinearDAG() {
        let nodes = (1 ... 5).map { node($0, deps: $0 == 1 ? [] : [$0 - 1]) }
        let expected: [IssueGraph.LayoutNode] = [
            .init(id: 1, x: 0, y: 0),
            .init(id: 2, x: 0, y: 1),
            .init(id: 3, x: 0, y: 2),
            .init(id: 4, x: 0, y: 3),
            .init(id: 5, x: 0, y: 4),
        ]

        #expect(IssueGraph.layeredLayout(nodes) == expected)
    }

    /// Three roots — pins within-level `x` ordering at `y == 0` (ascending by number).
    @Test("Orders three roots within the same level by number ascending")
    func ordersThreeRootsAscending() {
        let nodes = (1 ... 3).map { node($0) }
        let expected: [IssueGraph.LayoutNode] = [
            .init(id: 1, x: 0, y: 0),
            .init(id: 2, x: 1, y: 0),
            .init(id: 3, x: 2, y: 0),
        ]

        #expect(IssueGraph.layeredLayout(nodes) == expected)
    }

    /// Two children of one root — pins level computation for a shared dep set plus within-level
    /// ordering at a non-root level.
    @Test("Lays out two children of one root at the same y, ordered by number ascending")
    func laysOutTwoChildrenOfOneRoot() {
        let nodes = [node(1), node(2, deps: [1]), node(3, deps: [1])]
        let expected: [IssueGraph.LayoutNode] = [
            .init(id: 1, x: 0, y: 0),
            .init(id: 2, x: 0, y: 1),
            .init(id: 3, x: 1, y: 1),
        ]

        #expect(IssueGraph.layeredLayout(nodes) == expected)
    }

    /// A diamond where one path to the bottom node is shorter than the other — the smallest fixture
    /// that distinguishes longest-path (`max`) from shortest-path (`min`) level assignment.
    ///
    /// Mutation belt: swapping `max` for `min` in `computeLevels` collapses node 6 from `(0, 3)` to
    /// `(1, 2)` (alongside node 4), which this literal-array compare surfaces.
    @Test("Lays out a 6-node diamond using the longest path to compute level")
    func laysOutSixNodeDiamond() {
        let nodes = [
            node(1),
            node(2, deps: [1]),
            node(3, deps: [1]),
            node(4, deps: [2, 3]),
            node(5, deps: [1]),
            node(6, deps: [5, 4]),
        ]
        let expected: [IssueGraph.LayoutNode] = [
            .init(id: 1, x: 0, y: 0),
            .init(id: 2, x: 0, y: 1),
            .init(id: 3, x: 1, y: 1),
            .init(id: 5, x: 2, y: 1),
            .init(id: 4, x: 0, y: 2),
            .init(id: 6, x: 0, y: 3),
        ]

        #expect(IssueGraph.layeredLayout(nodes) == expected)
    }
}

/// Builds a `.pending` `DAGNode` with a generated title — the status is irrelevant to layout, which
/// keys only off `number` and `dependencies`.
func node(_ number: Int, deps: [Int] = []) -> DAGNode {
    DAGNode(number: number, title: "Issue \(number)", status: .pending, dependencies: deps)
}
