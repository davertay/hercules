extension IssueGraph {

    /// A node's position in a layered DAG layout, in integer column / level coordinates. Unit-free so
    /// it stays snapshot-testable and independent of presentation.
    public struct LayoutNode: Equatable, Sendable {
        public let id: Int
        /// Column within the level; nodes at the same `y` are ordered by `number` ascending.
        public let x: Int
        /// Level (longest path from any root). Roots have `y == 0`; a child is `1 + max(y of each dep)`.
        public let y: Int

        public init(id: Int, x: Int, y: Int) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    /// Layered DAG layout coordinates, returned sorted `(y, x)` ascending (row-major).
    ///
    /// `y` is the longest path from any root — not shortest, so a node is drawn *below* every node it
    /// depends on even when multiple paths to a root exist. `x` orders by `number` within the level;
    /// edge-crossing minimisation is deferred.
    ///
    /// Precondition: a validated DAG (acyclic, all dependencies declared); behaviour on a malformed
    /// graph is unspecified.
    public static func layeredLayout(_ nodes: [DAGNode]) -> [LayoutNode] {
        let levels = computeLevels(nodes)

        var byLevel: [Int: [Int]] = [:]
        for node in nodes {
            byLevel[levels[node.number, default: 0], default: []].append(node.number)
        }

        var layout: [LayoutNode] = []
        layout.reserveCapacity(nodes.count)
        for level in byLevel.keys.sorted() {
            let column = byLevel[level, default: []].sorted()
            for (x, number) in column.enumerated() {
                layout.append(LayoutNode(id: number, x: x, y: level))
            }
        }
        return layout
    }

    /// Each node's level via memoised longest-path-from-roots. Assumed acyclic, so the recursion
    /// terminates without an explicit visited set.
    private static func computeLevels(_ nodes: [DAGNode]) -> [Int: Int] {
        let byNumber: [Int: DAGNode] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })
        var levels: [Int: Int] = [:]

        func level(of number: Int) -> Int {
            if let cached = levels[number] { return cached }
            let node = byNumber[number]
            let computed: Int
            if let deps = node?.dependencies, !deps.isEmpty {
                computed = 1 + (deps.map(level(of:)).max() ?? 0)
            } else {
                computed = 0
            }
            levels[number] = computed
            return computed
        }

        for node in nodes {
            _ = level(of: node.number)
        }
        return levels
    }
}
