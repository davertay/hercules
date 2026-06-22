import Foundation
import SQLiteData

extension DatabaseWriter {
    /// Records `kind`'s Phase complete, inserting the row the first time and updating it on a re-run.
    /// `id` is evaluated only when a row is inserted.
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

    /// Completes a Phase whose Artifact is rows rather than a file (the Allocate Issues). The unlock
    /// gate keys only on `status == "complete"`, so a null path still unlocks the next Phase.
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
    public func latestFinalAnswer(forSession sessionID: UUID) throws -> String? {
        try read { db in
            try TurnRow
                .where { $0.sessionID.eq(sessionID) }
                .order { $0.createdAt.desc() }
                .fetchOne(db)
        }?.finalAnswer
    }
}
