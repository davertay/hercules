import Foundation
import SQLiteData
import Testing

@testable import Store

@Suite("Activity")
struct ActivityTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - IssueActivityRequest

    @Test func countsToolUsesAsToolsAndTextOrThinkingAsStepsExcludingToolResults() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedSession(database, id: UUID(20), workflowID: workflowID, issueNumber: 1)
        try Self.seedTurn(database, id: UUID(30), sessionID: UUID(20), at: Self.fixedDate)
        // Two tool_use, one text, one thinking, and a tool_result that must NOT be counted in either bucket.
        try Self.seedBlock(database, id: UUID(40), turnID: UUID(30), position: 0, kind: "thinking")
        try Self.seedBlock(database, id: UUID(41), turnID: UUID(30), position: 1, kind: "tool_use")
        try Self.seedBlock(database, id: UUID(42), turnID: UUID(30), position: 2, kind: "tool_result")
        try Self.seedBlock(database, id: UUID(43), turnID: UUID(30), position: 3, kind: "tool_use")
        try Self.seedBlock(database, id: UUID(44), turnID: UUID(30), position: 4, kind: "text")

        let activity = try database.read { db in
            try IssueActivityRequest(workflowID: workflowID).fetch(db)
        }

        #expect(activity[1]?.tools == 2)
        #expect(activity[1]?.steps == 2)
    }

    @Test func capturesEarliestTurnStartAndSumsDurationAndCost() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedSession(database, id: UUID(20), workflowID: workflowID, issueNumber: 1)
        try Self.seedTurn(
            database, id: UUID(30), sessionID: UUID(20),
            at: Self.fixedDate.addingTimeInterval(60), durationMs: 1000, costUSD: 0.02
        )
        try Self.seedTurn(
            database, id: UUID(31), sessionID: UUID(20),
            at: Self.fixedDate, durationMs: 500, costUSD: 0.01
        )

        let activity = try database.read { db in
            try IssueActivityRequest(workflowID: workflowID).fetch(db)
        }

        #expect(activity[1]?.startedAt == Self.fixedDate)
        #expect(activity[1]?.durationMs == 1500)
        #expect(activity[1]?.costUSD == 0.03)
    }

    @Test func countsOnlyTheLatestSessionWhenAnIssueWasRetried() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        // First attempt: one tool_use.
        try Self.seedSession(
            database, id: UUID(20), workflowID: workflowID, issueNumber: 1, at: Self.fixedDate
        )
        try Self.seedTurn(database, id: UUID(30), sessionID: UUID(20), at: Self.fixedDate)
        try Self.seedBlock(database, id: UUID(40), turnID: UUID(30), position: 0, kind: "tool_use")
        // Retry: a newer session with three tool_uses — only this one should be reflected.
        try Self.seedSession(
            database, id: UUID(21), workflowID: workflowID, issueNumber: 1,
            at: Self.fixedDate.addingTimeInterval(120)
        )
        try Self.seedTurn(
            database, id: UUID(31), sessionID: UUID(21), at: Self.fixedDate.addingTimeInterval(120)
        )
        for (offset, position) in [50, 51, 52].enumerated() {
            try Self.seedBlock(
                database, id: UUID(60 + offset), turnID: UUID(31), position: position, kind: "tool_use"
            )
        }

        let activity = try database.read { db in
            try IssueActivityRequest(workflowID: workflowID).fetch(db)
        }

        #expect(activity[1]?.tools == 3)
    }

    @Test func issueActivityIgnoresOtherWorkflows() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        let other = UUID(2)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedWorkflow(database, workflowID: other)
        try Self.seedSession(database, id: UUID(21), workflowID: other, issueNumber: 1)
        try Self.seedTurn(database, id: UUID(31), sessionID: UUID(21), at: Self.fixedDate)
        try Self.seedBlock(database, id: UUID(41), turnID: UUID(31), position: 0, kind: "tool_use")

        let activity = try database.read { db in
            try IssueActivityRequest(workflowID: workflowID).fetch(db)
        }

        #expect(activity.isEmpty)
    }

    @Test func issueWithNoTurnsYetHasNoEntry() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedSession(database, id: UUID(20), workflowID: workflowID, issueNumber: 1)

        let activity = try database.read { db in
            try IssueActivityRequest(workflowID: workflowID).fetch(db)
        }

        #expect(activity[1] == nil)
    }

    // MARK: - ReviewActivityRequest

    @Test func reviewActivityKeysByPersonaKindViaTheRowSessionLink() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedSession(
            database, id: UUID(20), workflowID: workflowID, issueNumber: nil, kind: .validate
        )
        try Self.seedTurn(database, id: UUID(30), sessionID: UUID(20), at: Self.fixedDate)
        try Self.seedBlock(database, id: UUID(40), turnID: UUID(30), position: 0, kind: "tool_use")
        try Self.seedBlock(database, id: UUID(41), turnID: UUID(30), position: 1, kind: "text")
        try Self.seedReview(
            database, id: UUID(10), workflowID: workflowID, kind: "standards",
            status: "reviewed", sessionID: UUID(20)
        )

        let activity = try database.read { db in
            try ReviewActivityRequest(workflowID: workflowID).fetch(db)
        }

        #expect(activity["standards"]?.tools == 1)
        #expect(activity["standards"]?.steps == 1)
    }

    @Test func reviewWithoutASessionLinkHasNoEntry() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedReview(
            database, id: UUID(10), workflowID: workflowID, kind: "standards",
            status: "running", sessionID: nil
        )

        let activity = try database.read { db in
            try ReviewActivityRequest(workflowID: workflowID).fetch(db)
        }

        #expect(activity.isEmpty)
    }

    // MARK: - Helpers

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }

    private static func seedWorkflow(_ database: any DatabaseWriter, workflowID: UUID) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
        }
    }

    private static func seedSession(
        _ database: any DatabaseWriter, id: UUID, workflowID: UUID, issueNumber: Int?,
        kind: SessionKind = .execute, at createdAt: Date = fixedDate
    ) throws {
        try database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: id, workflowID: workflowID, worktreePath: "/worktree", mode: "write",
                    kind: kind.rawValue, issueNumber: issueNumber, createdAt: createdAt, updatedAt: createdAt
                )
            }
            .execute(db)
        }
    }

    private static func seedTurn(
        _ database: any DatabaseWriter, id: UUID, sessionID: UUID, at createdAt: Date,
        durationMs: Int? = nil, costUSD: Double? = nil
    ) throws {
        try database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: id, sessionID: sessionID, durationMs: durationMs, costUSD: costUSD,
                    createdAt: createdAt, updatedAt: createdAt
                )
            }
            .execute(db)
        }
    }

    private static func seedBlock(
        _ database: any DatabaseWriter, id: UUID, turnID: UUID, position: Int, kind: String
    ) throws {
        try database.write { db in
            try ContentBlockRow.insert {
                ContentBlockRow(
                    id: id, turnID: turnID, position: position, role: "assistant", kind: kind,
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func seedReview(
        _ database: any DatabaseWriter, id: UUID, workflowID: UUID, kind: String,
        status: String, sessionID: UUID?
    ) throws {
        try database.write { db in
            try ReviewRow.insert {
                ReviewRow(
                    id: id, workflowID: workflowID, kind: kind, status: status, sessionID: sessionID,
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }
}
