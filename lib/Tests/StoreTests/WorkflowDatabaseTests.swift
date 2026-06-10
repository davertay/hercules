import Dependencies
import Foundation
import SQLiteData
import Testing

@testable import Store

@Suite("WorkflowDatabase")
struct WorkflowDatabaseTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func openCreatesAllTablesEmpty() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let database = try openWorkflowDatabase(at: dir)

        let counts = try database.read { db in
            (
                workflows: try WorkflowRow.fetchAll(db).count,
                phases: try PhaseRow.fetchAll(db).count,
                sessions: try SessionRow.fetchAll(db).count,
                turns: try TurnRow.fetchAll(db).count,
                blocks: try ContentBlockRow.fetchAll(db).count
            )
        }

        #expect(counts.workflows == 0)
        #expect(counts.phases == 0)
        #expect(counts.sessions == 0)
        #expect(counts.turns == 0)
        #expect(counts.blocks == 0)
    }

    @Test func reopeningAndReapplyingSchemaIsIdempotent() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Opening the same directory twice must not error.
        _ = try openWorkflowDatabase(at: dir)
        let database = try openWorkflowDatabase(at: dir)

        // Re-running the registered migrations against an already-migrated connection is a no-op,
        // not a "table already exists" error — the schema is applied idempotently.
        var migrator = DatabaseMigrator()
        registerWorkflowMigrations(&migrator)
        try migrator.migrate(database)

        // Schema is intact and a row can still be inserted and read back.
        let id = UUID(0)
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: "/repo", createdAt: Self.fixedDate, updatedAt: Self.fixedDate)
            }
            .execute(db)
        }
        let rows = try database.read { db in try WorkflowRow.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
        #expect(rows.first?.repoPath == "/repo")
    }

    @Test func sessionRowPersistsKind() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let database = try openWorkflowDatabase(at: dir)
        let workflowID = UUID(0)
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: Self.fixedDate, updatedAt: Self.fixedDate)
            }
            .execute(db)
            try SessionRow.insert {
                SessionRow(
                    id: UUID(1), workflowID: workflowID, worktreePath: "/repo", mode: "readOnly",
                    kind: "prd", createdAt: Self.fixedDate, updatedAt: Self.fixedDate
                )
            }
            .execute(db)
        }

        let row = try database.read { db in try SessionRow.fetchOne(db) }
        #expect(row?.kind == "prd")
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}
