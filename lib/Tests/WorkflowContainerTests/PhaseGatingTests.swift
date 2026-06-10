import Dependencies
import Foundation
import SQLiteData
import Store
import Testing

@testable import WorkflowContainer

@Suite("Phase gating")
struct PhaseGatingTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    @MainActor
    func designUnlockedAndLaterPhasesLockedBeforeAnyArtifact() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = Self.makeModel(id: UUID(0), root: root)
        try await model.$completedPhases.load()

        #expect(model.isUnlocked(.design))
        #expect(!model.isUnlocked(.prd))
        #expect(!model.isUnlocked(.allocate))
        #expect(!model.isUnlocked(.execute))
        #expect(!model.isUnlocked(.validate))
    }

    @Test
    @MainActor
    func completingDesignUnlocksPRDReactively() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let model = Self.makeModel(id: id, root: root)
        let database = try #require(model.database)

        try await model.$completedPhases.load()
        #expect(!model.isUnlocked(.prd))

        // Design finishes: its `phase` row flips to complete with the summary Artifact.
        try await database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try PhaseRow.insert {
                PhaseRow(
                    id: UUID(-1),
                    workflowID: id,
                    kind: "design",
                    status: "complete",
                    artifactPath: "/wf/phases/design/summary.md",
                    createdAt: fixedDate,
                    updatedAt: fixedDate
                )
            }
            .execute(db)
        }
        try await model.$completedPhases.load()

        #expect(model.isUnlocked(.prd))
        // Allocate stays locked until PRD itself completes.
        #expect(!model.isUnlocked(.allocate))
    }

    @Test
    @MainActor
    func completingPRDUnlocksAllocateReactively() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let model = Self.makeModel(id: id, root: root)
        let database = try #require(model.database)

        try await model.$completedPhases.load()
        #expect(!model.isUnlocked(.allocate))

        // PRD finishes: its `phase` row flips to complete with the PRD Artifact.
        try await database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try PhaseRow.insert {
                PhaseRow(
                    id: UUID(-1),
                    workflowID: id,
                    kind: "prd",
                    status: "complete",
                    artifactPath: "/wf/phases/prd/prd.md",
                    createdAt: fixedDate,
                    updatedAt: fixedDate
                )
            }
            .execute(db)
        }
        try await model.$completedPhases.load()

        #expect(model.isUnlocked(.allocate))
        // Execute stays locked until Allocate itself completes.
        #expect(!model.isUnlocked(.execute))
    }

    /// The PRD surface is constructed eagerly alongside Design, scoped to the same Workflow store.
    @Test
    @MainActor
    func prdSurfaceIsConstructedEagerly() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = Self.makeModel(id: UUID(0), root: root)

        #expect(model.prdModel != nil)
    }

    /// A soft-deleted complete `phase` row must not unlock the next Phase.
    @Test
    @MainActor
    func softDeletedCompletionDoesNotUnlock() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let model = Self.makeModel(id: id, root: root)
        let database = try #require(model.database)

        try await database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try PhaseRow.insert {
                PhaseRow(
                    id: UUID(-1),
                    workflowID: id,
                    kind: "design",
                    status: "complete",
                    createdAt: fixedDate,
                    updatedAt: fixedDate,
                    isDeleted: true
                )
            }
            .execute(db)
        }
        try await model.$completedPhases.load()

        #expect(!model.isUnlocked(.prd))
    }

    @MainActor
    private static func makeModel(id: UUID, root: URL) -> WorkflowContainerModel {
        WorkflowContainerModel(
            data: WorkflowWindowData(
                id: id,
                directory: root.appending(component: id.uuidString),
                repoPath: "/repo"
            )
        )
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhaseGatingTests-\(UUID().uuidString)", isDirectory: true)
    }
}
