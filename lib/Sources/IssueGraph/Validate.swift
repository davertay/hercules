extension IssueGraph {

    public enum ValidateError: Error, Equatable, Sendable {
        /// `involving` is sorted ascending for a stable witness across traversal implementations.
        case cycle(involving: [Int])

        /// `node`'s `dependencies` references undeclared `dep` — typically a stale post-recommit ref.
        case unknownDependency(node: Int, dep: Int)
    }

    /// Throws the first violation. Missing-dependency detection runs *before* cycle detection so a typo
    /// surfaces as a typo, not as a structural problem to reverse-engineer.
    public static func validate(_ nodes: [DAGNode]) throws {
        try detectUnknownDependency(in: nodes)
        try detectCycle(in: nodes)
    }

    private static func detectUnknownDependency(in nodes: [DAGNode]) throws {
        let declared: Set<Int> = Set(nodes.map(\.number))
        for node in nodes {
            for dep in node.dependencies where !declared.contains(dep) {
                throw ValidateError.unknownDependency(node: node.number, dep: dep)
            }
        }
    }

    /// Kahn's algorithm: peel zero-indegree nodes; whatever remains is in a cycle.
    private static func detectCycle(in nodes: [DAGNode]) throws {
        var indegree: [Int: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0.dependencies.count) })

        // `dependents[dep]` lists the nodes to relax when `dep` is peeled.
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
