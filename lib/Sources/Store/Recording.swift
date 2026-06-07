import Foundation
import SQLiteData

/// Inserts the `session` row for a Session's first Turn. This is the database equivalent of the
/// old `hercules.session.started` framing line (ADR 0003 supersedes the JSONL transcript).
public func recordSessionStart(
    in database: any DatabaseWriter,
    sessionID: UUID,
    workflowID: UUID,
    worktreePath: String,
    mode: AgentMode,
    at now: Date
) throws {
    try database.write { db in
        try SessionRow.insert {
            SessionRow(
                id: sessionID,
                workflowID: workflowID,
                worktreePath: worktreePath,
                mode: mode.rawValue,
                createdAt: now,
                updatedAt: now
            )
        }
        .execute(db)
    }
}

/// Inserts the `turn` row a Turn projects into. The live `StreamProjector` finalizes this same row
/// from the Harness's `result` event; on failure the Agent flags it via `recordFailure`.
public func recordTurnStart(
    in database: any DatabaseWriter,
    turnID: UUID,
    sessionID: UUID,
    userPrompt: String,
    at now: Date
) throws {
    try database.write { db in
        try TurnRow.insert {
            TurnRow(id: turnID, sessionID: sessionID, userPrompt: userPrompt, createdAt: now, updatedAt: now)
        }
        .execute(db)
    }
}
