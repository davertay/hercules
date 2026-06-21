import Foundation
import SQLiteData

extension DatabaseReader {
    /// The existing Session row for a `(workflowID, kind)` pair, or `nil` when none has been started
    /// yet. The invariant is one Session per pair (ADR 0005); if several somehow exist the earliest
    /// is returned so rediscovery is deterministic. A `Chat` engine calls this on construction to
    /// reconstitute its resumable Session and pick up prior history.
    public func existingSession(workflowID: UUID, kind: SessionKind) throws -> SessionRow? {
        try read { db in
            try SessionRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq(kind.rawValue) }
                .where { !$0.isDeleted }
                .order { $0.createdAt.asc() }
                .fetchOne(db)
        }
    }

    /// The Execute-run Session that worked the Issue numbered `number` in `workflowID`, or `nil` when
    /// none has run yet. The Execute orchestrator tags each per-Issue write Session with its
    /// `issueNumber`; this is the reverse lookup that makes a worked (especially failed) Issue's
    /// transcript recoverable. If a re-run produced several the earliest is returned, for determinism.
    public func session(forIssue number: Int, workflowID: UUID) throws -> SessionRow? {
        try read { db in
            try SessionRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.issueNumber.eq(number) }
                .where { !$0.isDeleted }
                .order { $0.createdAt.asc() }
                .fetchOne(db)
        }
    }
}
