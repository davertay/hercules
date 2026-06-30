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
}
