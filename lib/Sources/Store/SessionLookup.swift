import Foundation
import SQLiteData

/// The existing Session for a `(workflowID, kind)` pair (one per pair, ADR 0005), or `nil` — as an
/// *observable* request, so a surface picks up a Session created *after* it began observing rather than
/// only at construction. This is what lets Allocate's design-resuming engines (built at window open,
/// before the grill Session exists) rediscover the grill the moment the Design Phase starts it, instead
/// of staying stuck with the `nil` they captured at init and leaving both fork buttons disabled. The
/// earliest non-deleted match wins so rediscovery stays deterministic if several somehow exist.
public struct ExistingSessionRequest: FetchKeyRequest {
    public var workflowID: UUID
    public var kind: SessionKind

    public init(workflowID: UUID, kind: SessionKind) {
        self.workflowID = workflowID
        self.kind = kind
    }

    public func fetch(_ db: Database) throws -> SessionRow? {
        try SessionRow
            .where { $0.workflowID.eq(workflowID) }
            .where { $0.kind.eq(kind.rawValue) }
            .where { !$0.isDeleted }
            .order { $0.createdAt.asc() }
            .fetchOne(db)
    }
}

extension DatabaseReader {
    /// A one-shot read of ``ExistingSessionRequest`` — the earliest non-deleted Session for a
    /// `(workflowID, kind)` pair, or `nil`. Used to seed the observable lookup synchronously at
    /// construction; the observation then keeps it live.
    public func existingSession(workflowID: UUID, kind: SessionKind) throws -> SessionRow? {
        try read { db in
            try ExistingSessionRequest(workflowID: workflowID, kind: kind).fetch(db)
        }
    }

    /// The Execute-run Session that worked Issue `number`, or `nil` — the reverse lookup of the
    /// `issueNumber` tag that makes a worked Issue's transcript recoverable. Latest wins on a re-run, so
    /// the transcript shown is the run that produced the Issue's current state, not a stale earlier
    /// attempt. This mirrors Validate, whose `review.sessionID` already points at the latest run.
    public func session(forIssue number: Int, workflowID: UUID) throws -> SessionRow? {
        try read { db in
            try SessionRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.issueNumber.eq(number) }
                .where { !$0.isDeleted }
                .order { $0.createdAt.desc() }
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

    /// The most recent *errored* Turn's `finalAnswer` for the Issue's latest Execute Session, or `nil` —
    /// the Harness's own words on the failing turn, among them the session-limit notice Execute's
    /// auto-resume classifies (#160). Read fresh (not the lazily-updated observation) so the run loop can
    /// classify a fault the instant it lands. Guarded on `isError` so a cleanly-finished no-op Turn's
    /// answer never masquerades as an error message, and scoped to the *latest* Session so a re-run reads
    /// its own new message rather than re-arming on a stale earlier attempt's.
    public func latestExecuteErrorMessage(forIssue number: Int, workflowID: UUID) throws -> String? {
        try read { db in
            let session = try SessionRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq(SessionKind.execute.rawValue) }
                .where { $0.issueNumber.eq(number) }
                .where { !$0.isDeleted }
                .order { $0.createdAt.desc() }
                .fetchOne(db)
            guard let session else { return nil }
            return try TurnRow
                .where { $0.sessionID.eq(session.id) }
                .where { $0.isError }
                .where { !$0.isDeleted }
                .order { $0.createdAt.desc() }
                .fetchOne(db)?
                .finalAnswer
        }
    }
}
