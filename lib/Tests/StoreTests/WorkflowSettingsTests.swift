import Dependencies
import Foundation
import SQLiteData
import Testing

@testable import Store

@Suite("Workflow settings")
struct WorkflowSettingsTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// New Workflows land untrusting, and a Workflow migrated from before the column existed reads the
    /// same way — the migration's `DEFAULT 0` deliberately does not grandfather anyone in.
    @Test func trustDefaultsOffOnANewRow() throws {
        let workflow = try Self.makeWorkflow()
        defer { workflow.cleanUp() }

        let row = try #require(workflow.database.read { db in try WorkflowRow.fetchOne(db) })
        #expect(row.trustsRepositorySettings == false)
        #expect(workflow.database.trustsRepositorySettings(workflowID: workflow.id) == false)
    }

    @Test func trustRoundTripsThroughTheStore() throws {
        let workflow = try Self.makeWorkflow()
        defer { workflow.cleanUp() }

        try workflow.setTrust(true)

        #expect(workflow.database.trustsRepositorySettings(workflowID: workflow.id) == true)
    }

    /// The read is scoped to the Workflow asked for, and answers safely for anything else.
    @Test func trustReadsFalseForAnUnknownWorkflow() throws {
        let workflow = try Self.makeWorkflow()
        defer { workflow.cleanUp() }

        try workflow.setTrust(true)

        #expect(workflow.database.trustsRepositorySettings(workflowID: UUID(1)) == false)
    }

    /// A soft-deleted Workflow can't lend its trust to anything either.
    @Test func trustReadsFalseForADeletedWorkflow() throws {
        let workflow = try Self.makeWorkflow()
        defer { workflow.cleanUp() }

        try workflow.setTrust(true)
        try workflow.database.write { db in
            try WorkflowRow.where { $0.id.eq(workflow.id) }.update { $0.isDeleted = true }.execute(db)
        }

        #expect(workflow.database.trustsRepositorySettings(workflowID: workflow.id) == false)
    }

    /// A migrated database in a temp directory, with one `workflow` row inserted.
    private struct Fixture {
        let database: any DatabaseWriter
        let id: UUID
        let directory: URL

        func setTrust(_ trusts: Bool) throws {
            try database.write { db in
                try WorkflowRow
                    .where { $0.id.eq(id) }
                    .update { $0.trustsRepositorySettings = trusts }
                    .execute(db)
            }
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func makeWorkflow() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowSettingsTests-\(UUID().uuidString)", isDirectory: true)
        let database = try openWorkflowDatabase(at: directory)
        let id = UUID(0)
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
        }
        return Fixture(database: database, id: id, directory: directory)
    }
}
