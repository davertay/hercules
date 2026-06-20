extension IssueGraph {

    /// A single node's position in a layered DAG layout, in integer column / level coordinates.
    ///
    /// Suitable for direct consumption by the rect-based DAG view: it groups nodes by `y` to derive
    /// rows and orders within each row by `x`. The layout itself stays unit-free so it remains
    /// snapshot-testable and independent of presentation concerns.
    public struct LayoutNode: Equatable, Sendable {
        /// The Issue `number` this position belongs to.
        public let id: Int
        /// The column within the level. Nodes at the same `y` are ordered by `number` ascending.
        public let x: Int
        /// The level (longest path from any root). Roots have `y == 0`; a child's level is
        /// `1 + max(y of each dependency)`.
        public let y: Int

        public init(id: Int, x: Int, y: Int) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    /// Computes layered DAG layout coordinates for a `[DAGNode]` graph.
    ///
    /// **Contract** (the part the DAG view keys off):
    ///
    /// - `y` is the level, computed as the longest path from any root to the node. Roots (no
    ///   dependencies) live at `y == 0`; a child's level is `1 + max(y of each dependency)`.
    ///   Longest-path (not shortest) is the canonical layered-DAG choice — it ensures a node is drawn
    ///   *below* every node it depends on, even when multiple paths to a root exist.
    /// - `x` is the column within the level, ordered by `number` ascending. Deterministic; iteration
    ///   toward edge-crossing minimisation is deferred until the UI demands it.
    /// - The returned array is sorted by `(y ascending, x ascending)` — row-major, top-to-bottom,
    ///   left-to-right.
    ///
    /// **Preconditions:** the input is assumed to be a validated DAG (acyclic, all `dependencies`
    /// declared). Callers run `validate(_:)` upstream and surface its errors; behaviour on a
    /// malformed graph (cycle or unknown dependency) is unspecified.
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

    /// Computes each node's level via longest-path-from-roots, memoising into the returned dictionary
    /// keyed by Issue `number`. Each node's level is `0` if it has no dependencies, otherwise
    /// `1 + max(level of each dependency)`. The input is assumed acyclic, so recursion terminates
    /// without an explicit visited set.
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
