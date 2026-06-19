import Foundation
import SQLiteData

// Shared data-layer helpers behind a Phase's finalization: the insert-or-update of a Phase row to
// `complete`, and the lookup of a Session's latest final answer. File writing stays in the feature
// models; only the database mutation and query live here so there is one implementation each.

extension DatabaseWriter {
    /// Records `kind`'s Phase as complete with its Artifact path, inserting the Phase row the first
    /// time and updating it on a re-run. `id` is evaluated only when a row is inserted.
    public func completePhase(
        workflowID: UUID,
        kind: String,
        artifactPath: String,
        id: @autoclosure () -> UUID,
        now: Date
    ) throws {
        try completePhase(
            workflowID: workflowID, kind: kind, artifactPath: artifactPath, id: id, now: now
        )
    }

    /// Records `kind`'s Phase as complete with no Artifact path, for a Phase whose Artifact is rows in
    /// the database (the Allocate Issues) rather than a file. The unlock gate keys only on
    /// `status == "complete"`, so a null path still unlocks the next Phase.
    public func completePhase(
        workflowID: UUID,
        kind: String,
        id: @autoclosure () -> UUID,
        now: Date
    ) throws {
        try completePhase(
            workflowID: workflowID, kind: kind, artifactPath: nil, id: id, now: now
        )
    }

    private func completePhase(
        workflowID: UUID,
        kind: String,
        artifactPath: String?,
        id: () -> UUID,
        now: Date
    ) throws {
        try write { db in
            let existing = try PhaseRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq(kind) }
                .fetchOne(db)
            if let existing {
                try PhaseRow
                    .find(existing.id)
                    .update {
                        $0.status = "complete"
                        $0.artifactPath = #bind(artifactPath)
                        $0.updatedAt = now
                    }
                    .execute(db)
            } else {
                try PhaseRow.insert {
                    PhaseRow(
                        id: id(),
                        workflowID: workflowID,
                        kind: kind,
                        status: "complete",
                        artifactPath: artifactPath,
                        createdAt: now,
                        updatedAt: now
                    )
                }
                .execute(db)
            }
        }
    }
}

extension DatabaseReader {
    /// The final answer of `sessionID`'s most recent Turn, or `nil` when the Session has no Turn yet
    /// or that Turn has no final answer recorded.
    public func latestFinalAnswer(forSession sessionID: UUID) throws -> String? {
        try read { db in
            try TurnRow
                .where { $0.sessionID.eq(sessionID) }
                .order { $0.createdAt.desc() }
                .fetchOne(db)
        }?.finalAnswer
    }
}
