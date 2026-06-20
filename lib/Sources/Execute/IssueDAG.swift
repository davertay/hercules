import IssueGraph
import Store

/// Maps a Workflow's committed Issue rows to the `DAGNode`s the Execute Phase's DAG renders, deriving
/// each node's display status from the persisted status string plus the dependency graph.
///
/// This is the seam between persistence (`Store.IssueRow`, a free `String` status) and presentation
/// (`IssueGraph.IssueStatus`). It is a **graph-level** transform, not a per-row map: `.ready` can't be
/// decided from a single row — it depends on whether every dependency has reached `.done`.
///
/// - The raw status string maps to a base `IssueStatus` (today every committed Issue is `"new"`,
///   which maps to `.pending`; the other names are mapped too so the function is ready when
///   orchestration starts writing them).
/// - A `.pending` node whose every dependency is `.done` is promoted to `.ready`. Root Issues (no
///   dependencies) satisfy this vacuously, so they render `.ready` (blue) the moment the breakdown is
///   committed — the graph isn't a uniform sea of grey before any agent runs.
func dagNodes(from issues: [IssueRow]) -> [DAGNode] {
    let baseStatus: [Int: IssueStatus] = Dictionary(
        uniqueKeysWithValues: issues.map { ($0.number, mapStatus($0.status)) }
    )

    return issues.map { issue in
        let base = baseStatus[issue.number] ?? .pending
        let derived: IssueStatus =
            base == .pending && issue.dependencies.allSatisfy { baseStatus[$0] == .done }
            ? .ready
            : base
        return DAGNode(
            number: issue.number,
            title: issue.title,
            status: derived,
            dependencies: issue.dependencies
        )
    }
}

/// Maps a persisted `IssueRow.status` string to its base `IssueStatus`. `"new"` (the only value the
/// Allocate Phase writes today) is the post-commit starting state and maps to `.pending`; the remaining
/// names match the future orchestration vocabulary. An unrecognised value degrades to `.pending` rather
/// than crashing the view.
func mapStatus(_ raw: String) -> IssueStatus {
    switch raw {
    case "new", "pending": .pending
    case "ready": .ready
    case "in_progress": .inProgress
    case "done": .done
    case "failed": .failed
    case "skipped": .skipped
    default: .pending
    }
}
