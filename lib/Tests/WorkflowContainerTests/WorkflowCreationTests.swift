import Dependencies
import Foundation
import SQLiteData
import Store
import Testing

@testable import WorkflowContainer

@Suite("Workflow creation")
struct WorkflowCreationTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func createsDirectoryDatabaseAndRow() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let data = try withDependencies {
            // `.live` so the per-Workflow database is provisioned at the path under `root` rather
            // than the throwaway temp file the test context otherwise hands back.
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
        } operation: {
            try createWorkflow(repo: URL(fileURLWithPath: "/path/to/repo"), root: root)
        }

        #expect(data.id == UUID(0))
        #expect(data.repoPath == "/path/to/repo")
        #expect(data.directory == root.appending(component: UUID(0).uuidString))
        #expect(FileManager.default.fileExists(atPath: data.directory.path))
        #expect(
            FileManager.default.fileExists(
                atPath: data.directory.appendingPathComponent("workflow.sqlite").path
            )
        )

        // The row persists: reopening the same directory reads it back.
        let database = try withDependencies { $0.context = .live } operation: {
            try openWorkflowDatabase(at: data.directory)
        }
        defer { try? database.close() }
        let rows = try database.read { db in try WorkflowRow.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.id == UUID(0))
        #expect(rows.first?.repoPath == "/path/to/repo")
        #expect(rows.first?.createdAt == Self.fixedDate)
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowContainerTests-\(UUID().uuidString)", isDirectory: true)
    }
}
