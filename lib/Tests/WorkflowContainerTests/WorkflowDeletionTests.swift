import Dependencies
import Foundation
import SQLiteData
import Store
import Testing
import Worktree

@testable import WorkflowContainer

@Suite("Workflow deletion")
struct WorkflowDeletionTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func removesFolderSoListingNoLongerReturnsIt() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.worktreeClient = .testValue
        } operation: {
            let data = try createWorkflow(repo: URL(fileURLWithPath: "/path/to/repo"), root: root)
            #expect(FileManager.default.fileExists(atPath: data.directory.path))
            #expect(listWorkflows(root: root).count == 1)

            return deleteWorkflow(data: data, root: root)
        }

        // The clean git path leaves nothing to report.
        #expect(result.didGitCleanupSucceed)
        // The folder is gone, and the listing no longer surfaces the Workflow.
        let directory = root.appending(component: UUID(0).uuidString)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(listWorkflows(root: root).isEmpty)
    }

    @Test
    func removesWorktreeAndBranchOffShortID() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let captured = LockIsolated<RemoveWorktreeRequest?>(nil)
        let data = try withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.worktreeClient = .testValue
        } operation: {
            let data = try createWorkflow(repo: URL(fileURLWithPath: "/path/to/repo"), root: root)
            withDependencies {
                $0.worktreeClient.remove = { @Sendable request in captured.setValue(request) }
            } operation: {
                deleteWorkflow(data: data, root: root)
            }
            return data
        }

        let request = try #require(captured.value)
        #expect(request.repo == URL(fileURLWithPath: "/path/to/repo"))
        #expect(request.worktree == data.directory.appending(component: "worktree"))
        // The first incrementing UUID is all-zeroes, so the short id is its leading eight zeroes.
        #expect(request.branch == "hercules/00000000")
    }

    @Test
    func stillRemovesFolderAndSignalsWhenGitRemoveFails() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        struct RemoveFailure: Error {}
        let result = try withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.worktreeClient = .testValue
        } operation: {
            let data = try createWorkflow(repo: URL(fileURLWithPath: "/path/to/repo"), root: root)
            return withDependencies {
                $0.worktreeClient.remove = { @Sendable _ in throw RemoveFailure() }
            } operation: {
                deleteWorkflow(data: data, root: root)
            }
        }

        // The git failure is signalled to the caller...
        #expect(!result.didGitCleanupSucceed)
        #expect(try #require(result.gitCleanupError) is RemoveFailure)
        // ...but the folder is still gone — removal is the operation of record.
        let directory = root.appending(component: UUID(0).uuidString)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(listWorkflows(root: root).isEmpty)
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowContainerTests-\(UUID().uuidString)", isDirectory: true)
    }
}
