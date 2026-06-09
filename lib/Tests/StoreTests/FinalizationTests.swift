import Foundation
import SQLiteData
import Testing

@testable import Store

@Suite("Finalization")
struct FinalizationTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - completePhase

    @Test func completePhaseInsertsTheFirstTime() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        try database.completePhase(
            workflowID: workflowID, kind: "design", artifactPath: "/wf/summary.md",
            id: UUID(2), now: Self.fixedDate
        )

        let phases = try database.read { db in
            try PhaseRow.where { $0.kind.eq("design") }.fetchAll(db)
        }
        #expect(phases.count == 1)
        #expect(phases.first?.id == UUID(2))
        #expect(phases.first?.workflowID == workflowID)
        #expect(phases.first?.status == "complete")
        #expect(phases.first?.artifactPath == "/wf/summary.md")
    }

    @Test func completePhaseUpdatesSameRowOnReRun() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        try database.completePhase(
            workflowID: workflowID, kind: "design", artifactPath: "/wf/first.md",
            id: UUID(2), now: Self.fixedDate
        )
        try database.completePhase(
            workflowID: workflowID, kind: "design", artifactPath: "/wf/second.md",
            id: UUID(3), now: Self.fixedDate.addingTimeInterval(60)
        )

        let phases = try database.read { db in
            try PhaseRow.where { $0.kind.eq("design") }.fetchAll(db)
        }
        #expect(phases.count == 1)
        #expect(phases.first?.id == UUID(2))
        #expect(phases.first?.status == "complete")
        #expect(phases.first?.artifactPath == "/wf/second.md")
        #expect(phases.first?.updatedAt == Self.fixedDate.addingTimeInterval(60))
    }

    // MARK: - latestFinalAnswer

    @Test func latestFinalAnswerReturnsMostRecentTurnsAnswer() throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(10)
        try Self.seedSession(database, sessionID: sessionID)
        try database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: UUID(20), sessionID: sessionID, finalAnswer: "# First",
                    createdAt: Self.fixedDate, updatedAt: Self.fixedDate
                )
            }
            .execute(db)
            try TurnRow.insert {
                TurnRow(
                    id: UUID(21), sessionID: sessionID, finalAnswer: "# Second",
                    createdAt: Self.fixedDate.addingTimeInterval(60), updatedAt: Self.fixedDate
                )
            }
            .execute(db)
        }

        #expect(try database.latestFinalAnswer(forSession: sessionID) == "# Second")
    }

    @Test func latestFinalAnswerIsNilWhenSessionHasNoTurn() throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(10)
        try Self.seedSession(database, sessionID: sessionID)

        #expect(try database.latestFinalAnswer(forSession: sessionID) == nil)
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

    private static func seedSession(_ database: any DatabaseWriter, sessionID: UUID) throws {
        let workflowID = UUID(1)
        try seedWorkflow(database, workflowID: workflowID)
        try database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: sessionID, workflowID: workflowID, worktreePath: "/repo", mode: "readOnly",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }
}
