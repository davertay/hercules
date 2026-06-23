import Dependencies
import Foundation
import SQLiteData

// Data-layer helpers for a Workflow's Validate reviews. One row per (workflowID, Persona kind), upserted
// on each run — there is no run history (per-run audit comes from the linked Session). The orchestrator
// owns these status writes directly, so they live here, mirroring `Issues.swift`.

extension DatabaseWriter {
    /// Upserts the (workflowID, kind) review to `status`, overwriting the prior run's row in place. The
    /// caller carries the captured `summary` on `reviewed` and a `failureReason` on `failed`; both default
    /// to `nil`, so a transition that omits them clears any stale value. A run never created before
    /// inserts a fresh row (the Persona was idle until now).
    public func upsertReview(
        workflowID: UUID,
        kind: String,
        to status: ReviewStatus,
        summary: String? = nil,
        failureReason: String? = nil,
        now: Date
    ) throws {
        @Dependency(\.uuid) var uuid
        try write { db in
            let existing = try ReviewRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq(kind) }
                .where { !$0.isDeleted }
                .fetchOne(db)
            if let existing {
                try ReviewRow
                    .find(existing.id)
                    .update {
                        $0.status = status.rawValue
                        $0.summary = summary
                        $0.failureReason = failureReason
                        $0.updatedAt = now
                    }
                    .execute(db)
            } else {
                try ReviewRow.insert {
                    ReviewRow(
                        id: uuid(), workflowID: workflowID, kind: kind, status: status.rawValue,
                        summary: summary, failureReason: failureReason, createdAt: now, updatedAt: now
                    )
                }
                .execute(db)
            }
        }
    }

    /// Forward-links the run's Session onto the (workflowID, kind) review row. Separate from the status
    /// upsert because the Session id is known only once the run starts.
    public func setReviewSession(
        workflowID: UUID,
        kind: String,
        sessionID: UUID,
        now: Date
    ) throws {
        try write { db in
            try ReviewRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq(kind) }
                .where { !$0.isDeleted }
                .update {
                    $0.sessionID = #bind(sessionID)
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Demotes every `running` review back to `failed`. Run when a Validate window opens: with no live
    /// orchestrator at that point, any `running` review is stale by definition (a crash/quit), mirroring
    /// `reconcileStaleInProgressIssues`.
    public func reconcileStaleRunningReviews(workflowID: UUID, now: Date) throws {
        try write { db in
            try ReviewRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.status.eq(ReviewStatus.running.rawValue) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = ReviewStatus.failed.rawValue
                    $0.failureReason = #bind("Interrupted — the run was stopped or the app quit while this review was running.")
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }
}
