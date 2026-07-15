import Foundation
import SQLiteData
import Testing

@testable import Store

@Suite("SessionLookup")
struct SessionLookupTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - session(forIssue:)

    @Test("Returns the latest run when an Issue has been executed more than once")
    func sessionForIssueReturnsLatestRun() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        // Two `execute` Sessions for the same Issue, an earlier re-run and the latest one. Insert the
        // later-`createdAt` Session first so the result can't accidentally match insertion order.
        try Self.seedSession(
            database, id: UUID(20), workflowID: workflowID, issueNumber: 7,
            at: Self.fixedDate.addingTimeInterval(60)
        )
        try Self.seedSession(
            database, id: UUID(10), workflowID: workflowID, issueNumber: 7, at: Self.fixedDate
        )

        let session = try #require(try database.session(forIssue: 7, workflowID: workflowID))

        #expect(session.id == UUID(20))
    }

    @Test("Returns nil when the Issue has never been executed")
    func sessionForIssueReturnsNilWhenNoRun() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        #expect(try database.session(forIssue: 7, workflowID: workflowID) == nil)
    }

    // MARK: - latestTurnFinalAnswer

    @Test("Returns the most recent Turn's answer")
    func latestTurnFinalAnswerReturnsMostRecentTurnsAnswer() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        let sessionID = UUID(10)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedSession(
            database, id: sessionID, workflowID: workflowID, issueNumber: nil, at: Self.fixedDate
        )
        try Self.seedTurn(database, id: UUID(20), sessionID: sessionID, answer: "# First", at: Self.fixedDate)
        try Self.seedTurn(
            database, id: UUID(21), sessionID: sessionID, answer: "# Second",
            at: Self.fixedDate.addingTimeInterval(60)
        )

        #expect(try database.latestTurnFinalAnswer(sessionID: sessionID) == "# Second")
    }

    @Test("Returns nil when the Session has no Turn")
    func latestTurnFinalAnswerIsNilWhenSessionHasNoTurn() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        let sessionID = UUID(10)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedSession(
            database, id: sessionID, workflowID: workflowID, issueNumber: nil, at: Self.fixedDate
        )

        #expect(try database.latestTurnFinalAnswer(sessionID: sessionID) == nil)
    }

    @Test("Skips a soft-deleted Turn")
    func latestTurnFinalAnswerSkipsSoftDeletedTurn() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        let sessionID = UUID(10)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedSession(
            database, id: sessionID, workflowID: workflowID, issueNumber: nil, at: Self.fixedDate
        )
        try Self.seedTurn(database, id: UUID(20), sessionID: sessionID, answer: "# Kept", at: Self.fixedDate)
        try Self.seedTurn(
            database, id: UUID(21), sessionID: sessionID, answer: "# Deleted",
            at: Self.fixedDate.addingTimeInterval(60), isDeleted: true
        )

        #expect(try database.latestTurnFinalAnswer(sessionID: sessionID) == "# Kept")
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
        kind: SessionKind = .execute, at createdAt: Date
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
        _ database: any DatabaseWriter, id: UUID, sessionID: UUID, answer: String,
        at createdAt: Date, isDeleted: Bool = false
    ) throws {
        try database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: id, sessionID: sessionID, finalAnswer: answer,
                    createdAt: createdAt, updatedAt: createdAt, isDeleted: isDeleted
                )
            }
            .execute(db)
        }
    }
}
