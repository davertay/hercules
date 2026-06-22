import Foundation
import SQLiteData

// Data-layer helpers for a Workflow's Issues. Issue creation happens out-of-process through the MCP
// write tool (ADR 0006); status writes the orchestrator owns directly, so they live here.

extension DatabaseWriter {
    /// Soft-deletes every non-deleted Issue so re-committing replaces the prior set cleanly.
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

    /// Writes the run status, and the `failureReason` alongside it: the caller passes the reason when
    /// moving to `failed`, and `nil` for every other transition clears any stale reason.
    public func setIssueStatus(
        workflowID: UUID,
        number: Int,
        to status: IssueRunStatus,
        failureReason: String? = nil,
        now: Date
    ) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = status.rawValue
                    $0.failureReason = failureReason
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Resets a `failed` Issue back to `new` and clears its failure reason so the run loop will pick it
    /// up again. Scoped to `failed` so it can't disturb a `done` or `in_progress` Issue.
    public func resetIssue(workflowID: UUID, number: Int, now: Date) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { $0.status.eq(IssueRunStatus.failed.rawValue) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = #bind("new")
                    $0.failureReason = #bind(String?.none)
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Demotes every `in_progress` Issue back to `failed`. Run at the start of an Execute run: with no
    /// live orchestrator at that point, any `in_progress` Issue is stale by definition (a crash/quit).
    public func reconcileStaleInProgressIssues(workflowID: UUID, now: Date) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.status.eq(IssueRunStatus.inProgress.rawValue) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = IssueRunStatus.failed.rawValue
                    $0.failureReason = #bind("Interrupted — the run was stopped or the app quit while this Issue was in progress.")
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }
}

/// A Workflow's non-deleted Issues ordered by per-Workflow `number`.
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
