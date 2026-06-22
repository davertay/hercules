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
