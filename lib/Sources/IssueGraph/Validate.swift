extension IssueGraph {

    /// Errors that surface when a `[DAGNode]` graph fails graph-level validation: acyclic, and every
    /// dependency references a declared node.
    ///
    /// Each discriminator's payload is load-bearing for the banner UI: callers render "found a cycle
    /// through Issues X, Y, Z" or "Issue N depends on unknown Issue M" without re-introspecting the
    /// underlying error.
    public enum ValidateError: Error, Equatable, Sendable {
        /// One or more nodes participate in a dependency cycle. `involving` lists the participating
        /// Issue numbers in ascending order to keep the assertion stable across traversal
        /// implementations.
        case cycle(involving: [Int])

        /// A node's `dependencies` references a `number` not declared anywhere in the input set —
        /// typically a stale reference left after a re-commit. `node` is the offending Issue; `dep` is
        /// the undeclared dependency it points at. The validator surfaces the **first** offending pair
        /// found, walking nodes in input order and each node's `dependencies` in declaration order.
        case unknownDependency(node: Int, dep: Int)
    }

    /// Validates a `[DAGNode]` graph: acyclic, and every dependency exists.
    ///
    /// Throws a typed error describing the first violation found. Missing-dependency detection runs
    /// **before** cycle detection: a typo that also happens to break the graph topology should surface
    /// as a typo, not as a structural problem the user has to reverse-engineer.
    public static func validate(_ nodes: [DAGNode]) throws {
        try detectUnknownDependency(in: nodes)
        try detectCycle(in: nodes)
    }

    /// Single-pass scan over each node's `dependencies` against the set of declared numbers. Throws
    /// `.unknownDependency(node:dep:)` for the first offending pair, walking nodes in input order and
    /// each node's `dependencies` in declaration order.
    private static func detectUnknownDependency(in nodes: [DAGNode]) throws {
        let declared: Set<Int> = Set(nodes.map(\.number))
        for node in nodes {
            for dep in node.dependencies where !declared.contains(dep) {
                throw ValidateError.unknownDependency(node: node.number, dep: dep)
            }
        }
    }

    /// Cycle detection via Kahn's algorithm: repeatedly peel zero-indegree nodes. Whatever remains
    /// participates in at least one cycle. Returns the leftover numbers sorted ascending for a stable
    /// canonical witness regardless of traversal order.
    private static func detectCycle(in nodes: [DAGNode]) throws {
        var indegree: [Int: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0.dependencies.count) })

        // `dependents[dep]` lists the nodes that depend on `dep` — the edges to relax when `dep` is
        // peeled.
        var dependents: [Int: [Int]] = [:]
        for node in nodes {
            for dep in node.dependencies {
                dependents[dep, default: []].append(node.number)
            }
        }

        var ready = indegree.compactMap { $0.value == 0 ? $0.key : nil }
        var peeled: Set<Int> = []
        while let next = ready.popLast() {
            peeled.insert(next)
            for dependent in dependents[next] ?? [] {
                indegree[dependent, default: 0] -= 1
                if indegree[dependent] == 0 {
                    ready.append(dependent)
                }
            }
        }

        let unpeeled = nodes.map(\.number).filter { !peeled.contains($0) }
        if !unpeeled.isEmpty {
            throw ValidateError.cycle(involving: unpeeled.sorted())
        }
    }
}
