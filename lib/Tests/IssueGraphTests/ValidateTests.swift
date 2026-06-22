import Testing

@testable import IssueGraph

@Suite("IssueGraph.validate")
struct ValidateTests {

    @Test("Validates an empty graph cleanly")
    func validatesEmptyGraph() throws {
        try IssueGraph.validate([])
    }

    @Test("Validates a single node with no dependencies cleanly")
    func validatesSingleNodeNoDeps() throws {
        try IssueGraph.validate([node(1)])
    }

    @Test("Validates a 5-node linear DAG cleanly")
    func validatesFiveNodeLinearDAG() throws {
        let nodes = (1 ... 5).map { node($0, deps: $0 == 1 ? [] : [$0 - 1]) }
        try IssueGraph.validate(nodes)
    }

    @Test("Throws .unknownDependency when a dependency references an undeclared node")
    func throwsUnknownDependency() {
        let nodes = [node(1), node(2, deps: [99])]

        #expect(throws: IssueGraph.ValidateError.unknownDependency(node: 2, dep: 99)) {
            try IssueGraph.validate(nodes)
        }
    }

    @Test("Throws .cycle(involving: <sorted numbers>) for a dependency cycle")
    func throwsCycleForCycle() {
        // 1 → 2 → 3 → 1
        let nodes = [node(1, deps: [3]), node(2, deps: [1]), node(3, deps: [2])]

        #expect(throws: IssueGraph.ValidateError.cycle(involving: [1, 2, 3])) {
            try IssueGraph.validate(nodes)
        }
    }

    @Test("Throws a single-element .cycle for a node that depends on itself")
    func throwsCycleForSelfDependency() {
        #expect(throws: IssueGraph.ValidateError.cycle(involving: [1])) {
            try IssueGraph.validate([node(1, deps: [1])])
        }
    }

    @Test("Unknown-dependency takes precedence over cycle when both are present")
    func unknownDependencyTakesPrecedenceOverCycle() {
        // 1 → 2 → 3 → 1 cycle, and node 3 also depends on the undeclared 99.
        let nodes = [node(1, deps: [3]), node(2, deps: [1]), node(3, deps: [2, 99])]

        #expect(throws: IssueGraph.ValidateError.unknownDependency(node: 3, dep: 99)) {
            try IssueGraph.validate(nodes)
        }
    }
}
