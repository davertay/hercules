import Foundation
import SQLiteData

/// The Phase kinds recorded in `PhaseRow.kind` — the four sidebar Phases plus `prd`, the hidden
/// big-path checkpoint between Design and Allocate. The one home for the raw strings, so the
/// completion writers, the Artifact readers, and `WorkflowContainer.Phase` can't drift apart.
public enum PhaseKind: String, Codable, Sendable, CaseIterable {
    case design
    case prd
    case allocate
    case execute
    case validate
}

extension PhaseRow {
    /// The one status `completePhase` records — a Phase is either complete or has no live row at all.
    /// A constant rather than an enum until a second status exists.
    public static let completeStatus = "complete"
}

extension DatabaseWriter {
    /// Records `kind`'s Phase complete, inserting the row the first time and updating it on a re-run.
    /// `id` is evaluated only when a row is inserted.
    public func completePhase(
        workflowID: UUID,
        kind: PhaseKind,
        artifactPath: String,
        id: @autoclosure () -> UUID,
        now: Date
    ) throws {
        try completePhase(
            workflowID: workflowID, kind: kind, artifactPath: artifactPath, id: id, now: now
        )
    }

    /// Completes a Phase whose Artifact is rows rather than a file (the Allocate Issues). The unlock
    /// gate keys only on the complete status, so a null path still unlocks the next Phase.
    public func completePhase(
        workflowID: UUID,
        kind: PhaseKind,
        id: @autoclosure () -> UUID,
        now: Date
    ) throws {
        try completePhase(
            workflowID: workflowID, kind: kind, artifactPath: nil, id: id, now: now
        )
    }

    private func completePhase(
        workflowID: UUID,
        kind: PhaseKind,
        artifactPath: String?,
        id: () -> UUID,
        now: Date
    ) throws {
        try write { db in
            let existing = try PhaseRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq(kind.rawValue) }
                .fetchOne(db)
            if let existing {
                try PhaseRow
                    .find(existing.id)
                    .update {
                        $0.status = PhaseRow.completeStatus
                        $0.artifactPath = #bind(artifactPath)
                        // Resurrect a row a prior `reopenPhase` soft-deleted (e.g. an un-skipped PRD
                        // being generated): re-completing a Phase means it exists again.
                        $0.isDeleted = false
                        $0.updatedAt = now
                    }
                    .execute(db)
            } else {
                try PhaseRow.insert {
                    PhaseRow(
                        id: id(),
                        workflowID: workflowID,
                        kind: kind.rawValue,
                        status: PhaseRow.completeStatus,
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
    /// The file Artifact path recorded on `kind`'s completed, non-deleted Phase row, or `nil` when that
    /// Phase hasn't completed or wrote no Artifact. The single completed-Phase lookup shared by every
    /// reader; callers decide whether absence is an error (Allocate/PRD) or merely best-effort (Execute).
    public func completedArtifactPath(workflowID: UUID, kind: PhaseKind) throws -> String? {
        try read { db in try completedPhaseRow(db, workflowID: workflowID, kind: kind) }?.artifactPath
    }
}

extension DatabaseWriter {
    /// Reverses a Phase completion by soft-deleting its row, returning the Phase to its pre-completion
    /// (idle, and downstream re-locked) state — the un-skip path. A later `completePhase` resurrects the
    /// same row, so re-completing the Phase clears the soft-delete. A no-op when no live row exists.
    public func reopenPhase(workflowID: UUID, kind: PhaseKind, now: Date) throws {
        try write { db in
            try PhaseRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq(kind.rawValue) }
                .where { !$0.isDeleted }
                .update {
                    $0.isDeleted = true
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }
}

/// `kind`'s completed, non-deleted Phase row for a Workflow — the one definition of "the completed Phase"
/// query, shared by the one-shot reads (`completedArtifactPath`) and the live `@Fetch` observations.
public func completedPhaseRow(_ db: Database, workflowID: UUID, kind: PhaseKind) throws -> PhaseRow? {
    try PhaseRow
        .where { $0.workflowID.eq(workflowID) }
        .where { $0.kind.eq(kind.rawValue) }
        .where { $0.status.eq(PhaseRow.completeStatus) }
        .where { !$0.isDeleted }
        .fetchOne(db)
}

/// `kind`'s completed, non-deleted Phase row as an *observable* request — ``completedPhaseRow`` under
/// `@Fetch`. Design observes its own completion for the saved-summary banner; Allocate observes the
/// completed `design` Phase, whose `updatedAt` is the Design→Allocate cutover boundary its small path
/// filters the shared conversation against.
public struct CompletedPhaseRequest: FetchKeyRequest {
    public var workflowID: UUID
    public var kind: PhaseKind

    public init(workflowID: UUID, kind: PhaseKind) {
        self.workflowID = workflowID
        self.kind = kind
    }

    public func fetch(_ db: Database) throws -> PhaseRow? {
        try completedPhaseRow(db, workflowID: workflowID, kind: kind)
    }
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
