import Foundation
import SQLiteData

// Data-layer helpers for a Workflow's Issues. Issue creation happens out-of-process through the MCP
// write tool (ADR 0006); status writes the orchestrator owns directly, so they live here.

extension DatabaseWriter {
    /// Soft-deletes the given Issues by id. The transactional Allocate commit snapshots the prior set's
    /// ids, runs the writer Turn, and only clears those ids once the write has produced a non-empty new set.
    public func clearIssues(ids: Set<UUID>, workflowID: UUID, now: Date) throws {
        guard !ids.isEmpty else { return }
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.id.in(ids) }
                .where { !$0.isDeleted }
                .update {
                    $0.isDeleted = true
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Writes the run status, and the `failureReason` alongside it: the caller passes the reason when
    /// moving to `failed`, and `nil` for every other transition clears any stale reason.
    ///
    /// `done` additionally retires the Issue's `baselineSHA`: nothing re-runs a `done` Issue, so the
    /// baseline has nothing left to verify. Every other transition leaves it untouched — `inProgress` is
    /// written *before* the baseline is captured, and a `failed` attempt's baseline is precisely what the
    /// attempt after it needs.
    public func setIssueStatus(
        workflowID: UUID,
        number: Int,
        to status: IssueRow.Status,
        failureReason: String? = nil,
        now: Date
    ) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = status.rawValue
                    $0.failureReason = failureReason
                    $0.updatedAt = now
                }
                .execute(db)

            guard status == .done else { return }
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { !$0.isDeleted }
                .update { $0.baselineSHA = #bind(String?.none) }
                .execute(db)
        }
    }

    /// Records `sha` as the HEAD this Issue's work must move off, unless a baseline is already recorded,
    /// and returns whichever is now in force.
    ///
    /// Captured once — at the Issue's first attempt — and deliberately *not* refreshed by a re-run. An
    /// attempt cut off after committing (a session limit landing a minute after the commit) leaves work on
    /// the branch that the next attempt will rightly not repeat; measured against a re-read HEAD that
    /// attempt looks like a no-op, and measured against the first attempt's baseline it looks like what it
    /// is. `resetIssue` leaves the baseline alone for the same reason.
    public func captureIssueBaseline(workflowID: UUID, number: Int, sha: String, now: Date) throws -> String {
        try write { db in
            let recorded = try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { !$0.isDeleted }
                .fetchOne(db)?
                .baselineSHA
            if let recorded, !recorded.isEmpty { return recorded }

            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { !$0.isDeleted }
                .update {
                    $0.baselineSHA = #bind(sha)
                    $0.updatedAt = now
                }
                .execute(db)
            return sha
        }
    }

    /// Resets a `failed` Issue back to `new` and clears its failure reason so the run loop will pick it
    /// up again. Scoped to `failed` so it can't disturb a `done` or `in_progress` Issue. The
    /// `baselineSHA` survives on purpose: the retry is another attempt at the same Issue, and it must be
    /// measured against where the work started, not against whatever a cut-off predecessor committed.
    public func resetIssue(workflowID: UUID, number: Int, now: Date) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { $0.status.eq(IssueRow.Status.failed.rawValue) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = IssueRow.Status.new.rawValue
                    $0.failureReason = #bind(String?.none)
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Approves a HITL Proposed Issue: flips `proposed` → `new` so the next Execute run picks it up in
    /// dependency order (ADR 0007). Scoped to `proposed` so it can't disturb an already-running set.
    public func approveIssue(workflowID: UUID, number: Int, now: Date) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { $0.status.eq(IssueRow.Status.proposed.rawValue) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = IssueRow.Status.new.rawValue
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Denies a HITL Proposed Issue: soft-deletes it (like `clearIssues`) so it leaves the graph. Scoped to
    /// `proposed` so a normal Issue can't be removed this way.
    public func denyIssue(workflowID: UUID, number: Int, now: Date) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.number.eq(number) }
                .where { $0.status.eq(IssueRow.Status.proposed.rawValue) }
                .where { !$0.isDeleted }
                .update {
                    $0.isDeleted = true
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Demotes every `in_progress` Issue back to `failed`. Run at the start of an Execute run: with no
    /// live orchestrator at that point, any `in_progress` Issue is stale by definition (a crash/quit).
    public func reconcileStaleInProgressIssues(workflowID: UUID, now: Date) throws {
        try write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.status.eq(IssueRow.Status.inProgress.rawValue) }
                .where { !$0.isDeleted }
                .update {
                    $0.status = IssueRow.Status.failed.rawValue
                    $0.failureReason = #bind("Interrupted — the run was stopped or the app quit while this Issue was in progress.")
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }
}

/// Maps each Issue number to the Harness's own failure reason, recovered from the newest errored
/// `turn.finalAnswer` of the Issue's **latest** Execute-run Session. Unlike `issue.failureReason` (written
/// in-process when the run throws), this is projected live as the Turn streams — so it survives a
/// crash/quit and shows after a relaunch, and it carries the Harness's clean wording rather than the
/// wrapped `harnessFailed` message.
public struct IssueFailureReasonsRequest: FetchKeyRequest {
    public var workflowID: UUID

    public init(workflowID: UUID = UUID()) {
        self.workflowID = workflowID
    }

    public func fetch(_ db: Database) throws -> [Int: String] {
        // Execute-run Sessions carry the `issueNumber` tag (ADR 0005); map each back to its Issue, newest
        // first so only each Issue's latest Session is kept. Every re-run gets its own Session, and only
        // the last of them speaks for the Issue's current state — an earlier attempt's error (a session
        // limit, say) must not outlive the clean run that followed it.
        let sessions = try SessionRow
            .where { $0.workflowID.eq(workflowID) }
            .where { $0.kind.eq(SessionKind.execute.rawValue) }
            .where { !$0.isDeleted }
            .order { $0.createdAt.desc() }
            .fetchAll(db)
        var issueBySession: [UUID: Int] = [:]
        var latestSeen: Set<Int> = []
        for session in sessions {
            guard let number = session.issueNumber, latestSeen.insert(number).inserted else { continue }
            issueBySession[session.id] = number
        }
        guard !issueBySession.isEmpty else { return [:] }

        // Newest first again, so the first errored Turn seen per Issue is the last one of that latest
        // Session. An interrupt records an errored Turn with no `finalAnswer`; honoring only the latest
        // keeps a stale older reason from masking it — the Issue's own `failureReason` shows instead.
        let erroredTurns = try TurnRow
            .where { $0.isError }
            .order { $0.createdAt.desc() }
            .fetchAll(db)
        var reasons: [Int: String] = [:]
        var seen: Set<Int> = []
        for turn in erroredTurns {
            guard let number = issueBySession[turn.sessionID], !seen.contains(number) else { continue }
            seen.insert(number)
            if let answer = turn.finalAnswer, !answer.isEmpty { reasons[number] = answer }
        }
        return reasons
    }
}

/// A Workflow's non-deleted Issues ordered by per-Workflow `number`.
public struct WorkflowIssuesRequest: FetchKeyRequest {
    public var workflowID: UUID

    public init(workflowID: UUID = UUID()) {
        self.workflowID = workflowID
    }

    public func fetch(_ db: Database) throws -> [IssueRow] {
        try IssueRow
            .where { $0.workflowID.eq(workflowID) }
            .where { !$0.isDeleted }
            .order { $0.number.asc() }
            .fetchAll(db)
    }
}
