import Dependencies
import Foundation
import SQLiteData
import Store
import Testing

@testable import WorkflowContainer

@Suite("Workflow repository trust")
struct WorkflowTrustSettingTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// The settings sheet's toggle round-trips: it reads the stored value, and Done writes it back where
    /// the next Harness will read it.
    @Test
    @MainActor
    func togglingTrustPersistsAndFlowsBackToTheModel() async throws {
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

        // A Workflow starts untrusting, so the Harness loads the user's settings alone.
        #expect(model.trustsRepositorySettings == false)
        #expect(database.trustsRepositorySettings(workflowID: id) == false)

        withDependencies {
            $0.date.now = fixedDate
        } operation: {
            model.updateTrustsRepositorySettings(true)
        }
        try await model.$workflowRow.load()

        #expect(model.trustsRepositorySettings == true)
        #expect(database.trustsRepositorySettings(workflowID: id) == true)

        // And trust is revocable, which is the direction that has to work.
        withDependencies {
            $0.date.now = fixedDate
        } operation: {
            model.updateTrustsRepositorySettings(false)
        }
        try await model.$workflowRow.load()

        #expect(model.trustsRepositorySettings == false)
        #expect(database.trustsRepositorySettings(workflowID: id) == false)
    }

    /// Done commits the whole sheet in a single row write. The clock advances on every read, so a second
    /// write would stamp a later `updatedAt` — the first tick surviving is what says there was only one.
    @Test
    @MainActor
    func doneWritesTitleAndTrustInOneGo() async throws {
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

        let ticks = LockIsolated(0)
        withDependencies {
            $0.date = DateGenerator {
                fixedDate.addingTimeInterval(TimeInterval(ticks.withValue { $0 += 1; return $0 }))
            }
        } operation: {
            model.updateSettings(title: "  Add settings  ", trustsRepositorySettings: true)
        }
        try await model.$workflowRow.load()

        let row = try #require(model.workflowRow)
        #expect(row.title == "Add settings")
        #expect(row.trustsRepositorySettings == true)
        #expect(row.updatedAt == fixedDate.addingTimeInterval(1))
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowTrustSettingTests-\(UUID().uuidString)", isDirectory: true)
    }
}
