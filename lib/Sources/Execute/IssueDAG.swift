import IssueGraph
import Store

/// Maps committed Issue rows to `DAGNode`s, deriving display status from the status string plus the
/// dependency graph. A graph-level transform, not a per-row map: `.ready` can't be decided from one row
/// — a `.pending` node is promoted to `.ready` only when every dependency is `.done` (roots vacuously,
/// so they render ready the moment the breakdown is committed).
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

/// `"new"` (the post-commit starting state) maps to `.pending`; an unrecognised value degrades to
/// `.pending` rather than crashing the view.
func mapStatus(_ raw: String) -> IssueStatus {
    switch raw {
    case "new", "pending": .pending
    case "ready": .ready
    case "in_progress": .inProgress
    case "done": .done
    case "failed": .failed
    case "skipped": .skipped
    case "proposed": .proposed
    default: .pending
    }
}
