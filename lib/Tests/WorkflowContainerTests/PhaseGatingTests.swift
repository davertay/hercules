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
        #expect(!model.isUnlocked(.allocate))
        #expect(!model.isUnlocked(.execute))
        #expect(!model.isUnlocked(.validate))
    }

    @Test
    @MainActor
    func completingDesignUnlocksAllocateReactively() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let model = Self.makeModel(id: id, root: root)
        let database = try #require(model.database)

        try await model.$completedPhases.load()
        #expect(!model.isUnlocked(.allocate))

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

        #expect(model.isUnlocked(.allocate))
        // Execute stays locked until Allocate itself completes.
        #expect(!model.isUnlocked(.execute))
    }

    @Test
    @MainActor
    func completingAllocateUnlocksExecuteReactively() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let model = Self.makeModel(id: id, root: root)
        let database = try #require(model.database)

        try await model.$completedPhases.load()
        #expect(!model.isUnlocked(.execute))

        // Allocate finishes: its `phase` row flips to complete. Its Artifact is rows, not a file, so
        // the path is nil (mirrors `completePhase`'s nil-path completion).
        try await database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try PhaseRow.insert {
                PhaseRow(
                    id: UUID(-1),
                    workflowID: id,
                    kind: "allocate",
                    status: "complete",
                    createdAt: fixedDate,
                    updatedAt: fixedDate
                )
            }
            .execute(db)
        }
        try await model.$completedPhases.load()

        #expect(model.isUnlocked(.execute))
        // Validate stays locked until Execute itself completes.
        #expect(!model.isUnlocked(.validate))
    }

    @Test
    @MainActor
    func allFourPhaseSurfacesAreConstructedEagerly() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = Self.makeModel(id: UUID(0), root: root)

        #expect(model.designModel != nil)
        #expect(model.allocateModel != nil)
        #expect(model.executeModel != nil)
        #expect(model.validateModel != nil)
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

        #expect(!model.isUnlocked(.allocate))
    }

    // MARK: - Migration (clean break)

    /// A pre-existing Workflow from the two-topology era carries rows the collapsed enums no longer
    /// model — a `small`-mode `workflow` row, a completed `prd` Phase, and a `prd`-kind Session. Opening
    /// it must fail safe (no decode crash) and present the single four-Phase topology, ignoring the
    /// orphaned `prd` rows rather than taking the app down.
    @Test
    @MainActor
    func opensPreExistingOldTopologyWorkflowWithoutCrashing() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let directory = root.appending(component: id.uuidString)

        try withDependencies { $0.context = .live } operation: {
            let database = try openWorkflowDatabase(at: directory)
            defer { try? database.close() }
            try database.write { db in
                try WorkflowRow.insert {
                    WorkflowRow(id: id, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
                }
                .execute(db)
                // Stamp the vestigial `mode` column back to its old `small` value.
                try #sql(#"UPDATE "workflow" SET "mode" = 'small'"#).execute(db)
                try PhaseRow.insert {
                    PhaseRow(
                        id: UUID(-1), workflowID: id, kind: "design", status: "complete",
                        artifactPath: "/wf/phases/design/summary.md",
                        createdAt: fixedDate, updatedAt: fixedDate
                    )
                }
                .execute(db)
                try PhaseRow.insert {
                    PhaseRow(
                        id: UUID(-2), workflowID: id, kind: "prd", status: "complete",
                        artifactPath: "/wf/phases/prd/prd.md",
                        createdAt: fixedDate, updatedAt: fixedDate
                    )
                }
                .execute(db)
                try SessionRow.insert {
                    SessionRow(
                        id: UUID(-3), workflowID: id, worktreePath: "/repo", mode: "readOnly",
                        kind: "prd", createdAt: fixedDate, updatedAt: fixedDate
                    )
                }
                .execute(db)
            }
        }

        // Reopen the very same on-disk Workflow through the model.
        let model = withDependencies { $0.context = .live } operation: {
            WorkflowContainerModel(
                data: WorkflowWindowData(id: id, directory: directory, repoPath: "/repo")
            )
        }
        try await model.$completedPhases.load()

        // The four Phase surfaces are all present; nothing crashed on the stale rows.
        #expect(model.designModel != nil)
        #expect(model.allocateModel != nil)
        #expect(model.executeModel != nil)
        #expect(model.validateModel != nil)
        // Design is complete, so Allocate unlocks; the orphaned `prd` completion is simply ignored and
        // never unlocks anything of its own.
        #expect(model.isUnlocked(.design))
        #expect(model.isUnlocked(.allocate))
        #expect(!model.isUnlocked(.execute))
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
