import Foundation
import SQLiteData

extension DatabaseReader {
    /// The existing Session for a `(workflowID, kind)` pair (one per pair, ADR 0005), or `nil`. The
    /// earliest is returned so rediscovery stays deterministic if several somehow exist.
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

    /// The Execute-run Session that worked Issue `number`, or `nil` — the reverse lookup of the
    /// `issueNumber` tag that makes a worked Issue's transcript recoverable. Earliest wins on a re-run.
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

    /// The most recent non-deleted Turn's `finalAnswer` for a Session, or `nil` — the agent's parting
    /// words. Execute uses it to explain why an Issue produced no commit (e.g. "I'm blocked …"), since a
    /// cleanly-finished no-op Turn isn't an error and so escapes `IssueFailureReasonsRequest`.
    public func latestTurnFinalAnswer(sessionID: UUID) throws -> String? {
        try read { db in
            try TurnRow
                .where { $0.sessionID.eq(sessionID) }
                .where { !$0.isDeleted }
                .order { $0.createdAt.desc() }
                .fetchOne(db)
        }?.finalAnswer
    }
}
