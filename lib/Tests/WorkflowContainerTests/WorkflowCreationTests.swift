import Dependencies
import Foundation
import SQLiteData
import Store
import Testing
import Worktree

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
            // `.live` would otherwise reach for real git against the placeholder repo path.
            $0.worktreeClient = .testValue
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

    @Test
    func createsWorktreeUnderWorkflowDirectoryOnBranchOffShortID() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let captured = LockIsolated<CreateWorktreeRequest?>(nil)
        let data = try withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.worktreeClient.create = { @Sendable request in captured.setValue(request) }
        } operation: {
            try createWorkflow(repo: URL(fileURLWithPath: "/path/to/repo"), root: root)
        }

        let request = try #require(captured.value)
        #expect(request.repo == URL(fileURLWithPath: "/path/to/repo"))
        #expect(request.worktree == data.directory.appending(component: "worktree"))
        // The first incrementing UUID is all-zeroes, so the short id is its leading eight zeroes.
        #expect(request.branch == "hercules/00000000")
    }

    @Test
    func rollsBackDirectoryAndRowWhenWorktreeCreationFails() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        struct WorktreeFailure: Error {}
        #expect(throws: WorktreeFailure.self) {
            try withDependencies {
                $0.context = .live
                $0.uuid = .incrementing
                $0.date.now = Self.fixedDate
                $0.worktreeClient.create = { @Sendable _ in throw WorktreeFailure() }
            } operation: {
                try createWorkflow(repo: URL(fileURLWithPath: "/path/to/repo"), root: root)
            }
        }

        // No partially-created Workflow is left behind: the directory (and so its database row) is gone.
        let directory = root.appending(component: UUID(0).uuidString)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowContainerTests-\(UUID().uuidString)", isDirectory: true)
    }
}
