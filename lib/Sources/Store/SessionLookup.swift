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
}
