import Foundation
import SQLiteData

// Data-layer helpers for the Allocate Phase's Issues: clearing a Workflow's Issues before a
// re-commit, and observing the current set. Issue mutation otherwise happens out-of-process through
// the MCP write tool (ADR 0006); only the clear and the query live here.

extension DatabaseWriter {
    /// Soft-deletes (sets `isDeleted`) every non-deleted Issue of `workflowID`, so re-committing the
    /// Allocate breakdown replaces the prior set cleanly instead of accumulating duplicates.
    public func clearIssues(workflowID: UUID, now: Date) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { !$0.isDeleted }
                .update {
                    $0.isDeleted = true
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }
}

/// Fetches a Workflow's non-deleted Issues ordered by their per-Workflow `number`. Observing this
/// means committed Issues appear live and survive reopening the Workflow window. Mirrors
/// `CompletedPRDPhaseRequest`.
public struct WorkflowIssuesRequest: FetchKeyRequest {
    public var workflowID: UUID

    public init(workflowID: UUID = UUID()) {
        self.workflowID = workflowID
    }

    public func fetch(_ db: Database) throws -> [IssueRow] {
        try IssueRow
            .where { $0.workflowID.eq(workflowID) }
            .where { !$0.isDeleted }
            .order { $0.number.asc() }
            .fetchAll(db)
    }
}
