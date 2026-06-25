import Dependencies
import Foundation
import SQLiteData
import Store
import Testing

@testable import WorkflowContainer

@Suite("Workflow title")
struct WorkflowTitleTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func formatterUsesBareRepoNameWhenTitleEmpty() {
        #expect(workflowWindowDisplayTitle(repoPath: "/Users/me/projects/hercules", title: "") == "hercules")
    }

    @Test
    func formatterTreatsWhitespaceTitleAsEmpty() {
        #expect(workflowWindowDisplayTitle(repoPath: "/repo/hercules", title: "   ") == "hercules")
    }

    @Test
    func formatterIgnoresRepoNameWhenTitlePresent() {
        #expect(
            workflowWindowDisplayTitle(repoPath: "/Users/me/projects/hercules", title: "Add settings")
                == "Add settings"
        )
    }

    @Test
    func formatterFallsBackWhenRepoPathEmpty() {
        #expect(workflowWindowDisplayTitle(repoPath: "", title: "") == "Workflow")
        #expect(workflowWindowDisplayTitle(repoPath: "", title: "Named") == "Named")
    }

    @Test
    @MainActor
    func updatingTitlePersistsAndFlowsToDisplayTitle() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let model = withDependencies {
            $0.date.now = fixedDate
        } operation: {
            WorkflowContainerModel(
                data: WorkflowWindowData(
                    id: id,
                    directory: root.appending(component: id.uuidString),
                    repoPath: "/Users/me/projects/hercules"
                )
            )
        }
        let database = try #require(model.database)

        try await database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: "/Users/me/projects/hercules", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
        }
        try await model.$workflowRow.load()

        // Unnamed: displays the bare repo name.
        #expect(model.rawTitle == "")
        #expect(model.title == "hercules")

        withDependencies {
            $0.date.now = fixedDate
        } operation: {
            model.updateTitle("  Add settings  ")
        }
        try await model.$workflowRow.load()

        // Persisted trimmed, and the display title now carries the repo-name prefix.
        #expect(model.rawTitle == "Add settings")
        #expect(model.title == "Add settings")
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowTitleTests-\(UUID().uuidString)", isDirectory: true)
    }
}
