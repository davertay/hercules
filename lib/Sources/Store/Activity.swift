import Foundation
import SQLiteData

// Per-node activity counters surfaced on the Execute/Validate DAG cards (issue #134): how many tools the
// run has invoked, how much non-tool content (text + thinking) it has produced, when it started, and —
// once finalized — its wall-clock and cost. Derived live from the `content_block`/`turn` rows the
// `StreamProjector` writes as the Harness streams, so an in-progress card ticks up without polling.

/// The raw activity tallies for one run, before the feature model turns them into a render-ready
/// `NodeActivity` (which resolves live-vs-frozen elapsed and hides cost while running).
public struct ActivityCounts: Equatable, Sendable {
    /// `tool_use` blocks — the actions taken.
    public var tools: Int
    /// `text` + `thinking` blocks — the agent's non-tool content. `tool_result` is excluded: it's the
    /// user-role echo of each `tool_use` and would merely shadow the tool count.
    public var steps: Int
    /// Earliest Turn start of the run — the anchor a live elapsed timer counts from.
    public var startedAt: Date?
    /// Finalized wall-clock (summed across the run's Turns); `nil` until the run's `result` lands.
    public var durationMs: Int?
    /// Finalized cost in USD (summed across the run's Turns); `nil` until the run's `result` lands.
    public var costUSD: Double?

    public init(
        tools: Int = 0,
        steps: Int = 0,
        startedAt: Date? = nil,
        durationMs: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.tools = tools
        self.steps = steps
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.costUSD = costUSD
    }
}

/// Per-Issue activity for the Execute DAG, keyed by Issue `number`. A retried Issue has several
/// `execute` Sessions; only the latest is counted, so the card describes the current/most-recent attempt
/// rather than a lifetime sum (whose elapsed would be the meaningless sum of both runs' wall-clocks).
public struct IssueActivityRequest: FetchKeyRequest {
    public var workflowID: UUID

    public init(workflowID: UUID = UUID()) {
        self.workflowID = workflowID
    }

    public func fetch(_ db: Database) throws -> [Int: ActivityCounts] {
        // `execute` Sessions carry the `issueNumber` tag (ADR 0005). Ascending by `createdAt` so the last
        // write into the map per Issue is its latest run's Session.
        let sessions = try SessionRow
            .where { $0.workflowID.eq(workflowID) }
            .where { $0.kind.eq(SessionKind.execute.rawValue) }
            .where { !$0.isDeleted }
            .order { $0.createdAt.asc() }
            .fetchAll(db)

        var latestSessionByIssue: [Int: UUID] = [:]
        for session in sessions {
            if let number = session.issueNumber { latestSessionByIssue[number] = session.id }
        }
        guard !latestSessionByIssue.isEmpty else { return [:] }

        let issueBySession = Dictionary(
            uniqueKeysWithValues: latestSessionByIssue.map { ($0.value, $0.key) }
        )
        let counts = try activityCounts(forSessions: Set(issueBySession.keys), in: db)

        var result: [Int: ActivityCounts] = [:]
        for (session, number) in issueBySession {
            if let count = counts[session] { result[number] = count }
        }
        return result
    }
}

/// Per-Persona activity for the Validate board, keyed by the review Persona's `kind`. Each `review` row
/// forward-links its latest run's Session, so re-running a Persona repoints the link and the counters
/// reset to the new run.
public struct ReviewActivityRequest: FetchKeyRequest {
    public var workflowID: UUID

    public init(workflowID: UUID = UUID()) {
        self.workflowID = workflowID
    }

    public func fetch(_ db: Database) throws -> [String: ActivityCounts] {
        let reviews = try ReviewRow
            .where { $0.workflowID.eq(workflowID) }
            .where { !$0.isDeleted }
            .fetchAll(db)

        var kindBySession: [UUID: String] = [:]
        for review in reviews {
            if let session = review.sessionID { kindBySession[session] = review.kind }
        }
        guard !kindBySession.isEmpty else { return [:] }

        let counts = try activityCounts(forSessions: Set(kindBySession.keys), in: db)

        var result: [String: ActivityCounts] = [:]
        for (session, kind) in kindBySession {
            if let count = counts[session] { result[kind] = count }
        }
        return result
    }
}

/// Tallies content blocks per Session: counts `tool_use` and `text`/`thinking` blocks, and folds in each
/// Turn's start, duration, and cost. Aggregated in Swift (mirroring `IssueFailureReasonsRequest`) rather
/// than via a grouped SQL query, keeping the kind-bucketing legible. A Session with no Turns yet maps to
/// nothing — its card shows no footer until the first Turn row lands.
func activityCounts(forSessions sessionIDs: Set<UUID>, in db: Database) throws -> [UUID: ActivityCounts] {
    guard !sessionIDs.isEmpty else { return [:] }

    let turns = try TurnRow
        .where { !$0.isDeleted }
        .where { $0.sessionID.in(sessionIDs) }
        .fetchAll(db)
    guard !turns.isEmpty else { return [:] }

    let sessionByTurn = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0.sessionID) })

    var counts: [UUID: ActivityCounts] = [:]
    for turn in turns {
        var entry = counts[turn.sessionID] ?? ActivityCounts()
        entry.startedAt = [entry.startedAt, turn.createdAt].compactMap { $0 }.min()
        if let duration = turn.durationMs { entry.durationMs = (entry.durationMs ?? 0) + duration }
        if let cost = turn.costUSD { entry.costUSD = (entry.costUSD ?? 0) + cost }
        counts[turn.sessionID] = entry
    }

    let blocks = try ContentBlockRow
        .where { !$0.isDeleted }
        .where { $0.turnID.in(Set(turns.map(\.id))) }
        .fetchAll(db)
    for block in blocks {
        guard let session = sessionByTurn[block.turnID] else { continue }
        var entry = counts[session] ?? ActivityCounts()
        switch block.kind {
        case "tool_use": entry.tools += 1
        case "text", "thinking": entry.steps += 1
        default: break  // `tool_result` is the user-role echo of a `tool_use`; excluded.
        }
        counts[session] = entry
    }

    return counts
}
