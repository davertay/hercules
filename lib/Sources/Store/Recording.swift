import Foundation
import SQLiteData

/// Inserts the `session` row for a Session's first Turn.
public func recordSessionStart(
    in database: any DatabaseWriter,
    sessionID: UUID,
    workflowID: UUID,
    worktreePath: String,
    mode: AgentMode,
    kind: SessionKind,
    issueNumber: Int? = nil,
    at now: Date
) throws {
    try database.write { db in
        try SessionRow.insert {
            SessionRow(
                id: sessionID,
                workflowID: workflowID,
                worktreePath: worktreePath,
                mode: mode.rawValue,
                kind: kind.rawValue,
                issueNumber: issueNumber,
                createdAt: now,
                updatedAt: now
            )
        }
        .execute(db)
    }
}

/// Inserts the `turn` row; the `StreamProjector` later finalizes this same row from the `result` event.
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
