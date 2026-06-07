import Foundation
import SQLiteData
import Store

/// Creates a fresh on-disk Workflow database with one `workflow` row seeded, ready for the Agent to
/// project `session`/`turn`/`content_block` rows into. The `workflowID` satisfies the `session`
/// row's foreign key.
enum WorkflowFixture {
    static func make() throws -> (database: any DatabaseWriter, workflowID: UUID, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTests-\(UUID().uuidString)", isDirectory: true)
        let database = try openWorkflowDatabase(at: root)
        let workflowID = UUID()
        let now = Date()
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: root.path, createdAt: now, updatedAt: now)
            }
            .execute(db)
        }
        return (database, workflowID, root)
    }
}
