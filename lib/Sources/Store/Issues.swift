import Foundation
import SQLiteData

// Data-layer helpers for a Workflow's Issues. The Allocate Phase clears and observes the committed
// set; the Execute orchestrator advances each Issue's status through its run lifecycle. Issue
// creation otherwise happens out-of-process through the MCP write tool (ADR 0006); status writes,
// unlike creation, the orchestrator owns directly and so live here.

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

    /// Writes `status` onto the non-deleted Issue identified by (`workflowID`, `number`) and stamps its
    /// `updatedAt`. The Execute orchestrator calls this to move an Issue through its lifecycle
    /// (`in_progress` → `done`/`failed`); the resulting status string feeds the DAG's recolouring.
    public func setIssueStatus(
        workflowID: UUID,
        number: Int,
        to status: IssueRunStatus,
        now: Date
    ) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = status.rawValue
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Demotes every non-deleted Issue of `workflowID` stuck at `in_progress` back to `failed`,
    /// stamping `updatedAt`. Run at the start of an Execute run to clean up after a crash or forced
    /// quit: there is no live orchestrator at that point, so any `in_progress` Issue is stale by
    /// definition. Returns having converged the persisted state with reality before the run proceeds.
    public func reconcileStaleInProgressIssues(workflowID: UUID, now: Date) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.status.eq(IssueRunStatus.inProgress.rawValue) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = IssueRunStatus.failed.rawValue
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
