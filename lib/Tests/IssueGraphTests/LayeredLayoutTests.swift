import Testing

@testable import IssueGraph

@Suite("IssueGraph.layeredLayout")
struct LayeredLayoutTests {

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

    /// The smallest fixture distinguishing longest-path from shortest-path level assignment: swapping
    /// `max` for `min` in `computeLevels` would collapse node 6 from `(0, 3)` to `(1, 2)`.
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

    // MARK: - Isolated nodes

    @Test("Parks dependency-free, dependent-free nodes in a band below the deepest connected node")
    func parksIsolatedNodesInABottomBand() {
        // Connected diamond 1→{2,4}→3 (depth 2) plus two appended isolated nodes 5 and 6.
        let nodes = [
            node(1), node(2, deps: [1]), node(4, deps: [1]), node(3, deps: [2, 4]),
            node(5), node(6),
        ]
        let y = Dictionary(uniqueKeysWithValues: IssueGraph.layeredLayout(nodes).map { ($0.id, $0.y) })

        // The connected graph keeps its longest-path depths…
        #expect(y[1] == 0)
        #expect(y[2] == 1)
        #expect(y[4] == 1)
        #expect(y[3] == 2)
        // …and the isolated nodes sit one row below the deepest connected node (#3 at row 2).
        #expect(y[5] == 3)
        #expect(y[6] == 3)
    }

    @Test("Isolated nodes in the band are ordered by number ascending")
    func isolatedBandOrderedByNumber() {
        let nodes = [node(1), node(2, deps: [1]), node(9), node(7)]
        let band = IssueGraph.layeredLayout(nodes)
            .filter { $0.y == 2 }
            .sorted { $0.x < $1.x }

        #expect(band.map(\.id) == [7, 9])
    }

    @Test("A node that is depended upon is connected, not isolated, even with no dependencies of its own")
    func rootWithDependentsStaysAtTop() {
        // #1 has no deps but #2 depends on it, so #1 is a connected root, not a parked orphan.
        let y = Dictionary(uniqueKeysWithValues:
            IssueGraph.layeredLayout([node(1), node(2, deps: [1])]).map { ($0.id, $0.y) })

        #expect(y[1] == 0)
        #expect(y[2] == 1)
    }

    @Test("A graph of only isolated nodes lays out as a single row")
    func allIsolatedStaysOneRow() {
        // No connected nodes, so the band falls back to row 0 — a flat breakdown is unaffected.
        let layout = IssueGraph.layeredLayout((1 ... 4).map { node($0) })
        #expect(layout.allSatisfy { $0.y == 0 })
    }
}

/// Status is irrelevant to layout, which keys only off `number` and `dependencies`.
func node(_ number: Int, deps: [Int] = []) -> DAGNode {
    DAGNode(number: number, title: "Issue \(number)", status: .pending, dependencies: deps)
}
