extension IssueGraph {

    /// A node's position in a layered DAG layout, in integer column / level coordinates. Unit-free so
    /// it stays snapshot-testable and independent of presentation.
    public struct LayoutNode: Equatable, Sendable {
        public let id: Int
        /// Column within the level; nodes at the same `y` are ordered by `number` ascending.
        public let x: Int
        /// Level (row). A node is always drawn below every node it depends on; see `layeredLayout` for how
        /// dependency-free nodes are placed.
        public let y: Int

        public init(id: Int, x: Int, y: Int) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    /// Layered DAG layout coordinates, returned sorted `(y, x)` ascending (row-major).
    ///
    /// A *connected* node's level is its longest path from any root — not shortest, so it's drawn *below*
    /// every node it depends on even when multiple paths to a root exist. `x` orders by `number` within
    /// the level; edge-crossing minimisation is deferred.
    ///
    /// A node that is *fully isolated* — no dependencies and nothing depending on it — carries no
    /// dependency-depth signal, so rather than letting longest-path pile every such node onto the root row
    /// (where appended HITL Proposed Issues would otherwise distort the real graph), isolated nodes are
    /// parked together in a band one row below the deepest connected node, ordered by number.
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

    /// Longest-path levels for connected nodes, with fully isolated nodes (no deps, no dependents) moved to
    /// a band one row below the deepest connected node. Connected graphs are unaffected — an isolated node
    /// is free to sit at any depth without breaking the invariant that a node is below all its
    /// dependencies, so parking it at the bottom only changes where dependency-free orphans land.
    private static func computeLevels(_ nodes: [DAGNode]) -> [Int: Int] {
        let asap = longestPathLevels(nodes)
        let dependedUpon = Set(nodes.flatMap(\.dependencies))

        func isIsolated(_ node: DAGNode) -> Bool {
            node.dependencies.isEmpty && !dependedUpon.contains(node.number)
        }

        let maxConnectedLevel = nodes
            .filter { !isIsolated($0) }
            .map { asap[$0.number, default: 0] }
            .max()
        let bandLevel = maxConnectedLevel.map { $0 + 1 } ?? 0

        var levels: [Int: Int] = [:]
        for node in nodes {
            levels[node.number] = isIsolated(node) ? bandLevel : asap[node.number, default: 0]
        }
        return levels
    }

    /// Each node's level via memoised longest-path-from-roots. Assumed acyclic, so the recursion
    /// terminates without an explicit visited set.
    private static func longestPathLevels(_ nodes: [DAGNode]) -> [Int: Int] {
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
