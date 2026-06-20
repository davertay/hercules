import Foundation
import IssueGraph
import Store
import Testing

@testable import Execute

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Issue → DAGNode mapping")
struct IssueDAGTests {

    @Test("Maps every committed Issue to a node, preserving number, title, and dependencies")
    func mapsRowsToNodes() {
        let nodes = dagNodes(from: [
            issue(1, title: "Foundations"),
            issue(2, title: "Build on it", deps: [1]),
        ])

        #expect(nodes.count == 2)
        #expect(nodes[0].number == 1)
        #expect(nodes[0].title == "Foundations")
        #expect(nodes[1].dependencies == [1])
    }

    @Test("A root Issue (no dependencies) is vacuously ready")
    func rootIsReady() {
        let nodes = dagNodes(from: [issue(1)])

        #expect(nodes[0].status == .ready)
    }

    @Test("A pending Issue with an outstanding dependency stays pending")
    func pendingWithOutstandingDepStaysPending() {
        // #1 is new (→ pending, but a root so it derives ready); #2 depends on the not-done #1.
        let nodes = dagNodes(from: [
            issue(1),
            issue(2, deps: [1]),
        ])
        let byNumber = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })

        #expect(byNumber[1]?.status == .ready)
        #expect(byNumber[2]?.status == .pending)
    }

    @Test("A pending Issue becomes ready once every dependency is done")
    func readyDerivedWhenAllDepsDone() {
        let nodes = dagNodes(from: [
            issue(1, status: "done"),
            issue(2, status: "done"),
            issue(3, deps: [1, 2]),
        ])
        let byNumber = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })

        #expect(byNumber[3]?.status == .ready)
    }

    @Test("A pending Issue with one done and one outstanding dependency stays pending")
    func partiallySatisfiedStaysPending() {
        let nodes = dagNodes(from: [
            issue(1, status: "done"),
            issue(2),
            issue(3, deps: [1, 2]),
        ])
        let byNumber = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })

        // #2 is a root → ready, but #3's other dependency #2 is not done, so #3 stays pending.
        #expect(byNumber[3]?.status == .pending)
    }

    @Test("A dependency that failed does not satisfy readiness")
    func failedDepDoesNotSatisfyReadiness() {
        let nodes = dagNodes(from: [
            issue(1, status: "failed"),
            issue(2, deps: [1]),
        ])
        let byNumber = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })

        #expect(byNumber[2]?.status == .pending)
    }

    @Test("Non-pending statuses pass through unchanged (not re-derived to ready)")
    func nonPendingPassesThrough() {
        let nodes = dagNodes(from: [
            issue(1, status: "in_progress"),
            issue(2, status: "done"),
            issue(3, status: "failed"),
            issue(4, status: "skipped"),
        ])
        let byNumber = Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })

        #expect(byNumber[1]?.status == .inProgress)
        #expect(byNumber[2]?.status == .done)
        #expect(byNumber[3]?.status == .failed)
        #expect(byNumber[4]?.status == .skipped)
    }

    @Test("Raw status strings map to the matching IssueStatus; unknown degrades to pending")
    func mapsRawStatusStrings() {
        #expect(mapStatus("new") == .pending)
        #expect(mapStatus("pending") == .pending)
        #expect(mapStatus("ready") == .ready)
        #expect(mapStatus("in_progress") == .inProgress)
        #expect(mapStatus("done") == .done)
        #expect(mapStatus("failed") == .failed)
        #expect(mapStatus("skipped") == .skipped)
        #expect(mapStatus("something-unexpected") == .pending)
    }

    private func issue(
        _ number: Int,
        title: String = "Issue",
        deps: [Int] = [],
        status: String = "new"
    ) -> IssueRow {
        IssueRow(
            id: UUID(),
            workflowID: UUID(0),
            number: number,
            title: title,
            dependencies: deps,
            status: status,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
    }
}
