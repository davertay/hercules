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

    /// The file Artifact path recorded on `kind`'s completed, non-deleted Phase row, or `nil` when that
    /// Phase hasn't completed or wrote no Artifact. The single completed-Phase lookup shared by every
    /// reader; callers decide whether absence is an error (Allocate/PRD) or merely best-effort (Execute).
    public func completedArtifactPath(workflowID: UUID, kind: String) throws -> String? {
        try read { db in try completedPhaseRow(db, workflowID: workflowID, kind: kind) }?.artifactPath
    }
}

/// `kind`'s completed, non-deleted Phase row for a Workflow — the one definition of "the completed Phase"
/// query, shared by the one-shot reads (`completedArtifactPath`) and the live `@Fetch` observations.
public func completedPhaseRow(_ db: Database, workflowID: UUID, kind: String) throws -> PhaseRow? {
    try PhaseRow
        .where { $0.workflowID.eq(workflowID) }
        .where { $0.kind.eq(kind) }
        .where { $0.status.eq("complete") }
        .where { !$0.isDeleted }
        .fetchOne(db)
}

/// `absolutePath` expressed relative to the Workflow directory `root`, or unchanged when it doesn't sit
/// beneath `root`. The single place both Execute and Allocate turn an Artifact's absolute path into the
/// `root`-relative form an `InputBundle` wants.
public func workflowRelativePath(of absolutePath: String, under root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}
