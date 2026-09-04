import Foundation
import SQLiteData

// Data-layer helpers for a Workflow's own settings. The settings sheet owns the writes; the read lives
// here because every surface that spawns a Harness needs it.

extension DatabaseReader {
    /// Whether this Workflow trusts its repository's Claude Code settings — the opt-in that widens the
    /// Harness's `--setting-sources` from the user's own settings to the repository's as well.
    ///
    /// Read fresh at each Turn rather than pinned on the Session, so revoking trust takes effect on the
    /// next Harness invocation instead of waiting for a new Session — the long-lived chat Sessions would
    /// otherwise latch the toggle for the Workflow's whole life. `false` on a missing row or a failed
    /// read: not loading the repository's settings is the safe answer.
    public func trustsRepositorySettings(workflowID: UUID) -> Bool {
        let row = try? read { db in
            try WorkflowRow
                .where { $0.id.eq(workflowID) }
                .where { !$0.isDeleted }
                .fetchOne(db)
        }
        return (row ?? nil)?.trustsRepositorySettings ?? false
    }
}
