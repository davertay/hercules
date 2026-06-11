import Agent
import Dependencies
import Foundation
import Material
import SQLiteData
import Store
import Testing

@testable import PRD

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
@Suite("PRDModel")
struct PRDModelTests {

    // MARK: - Material wiring

    @Test
    func toPrdSkillResolvesFromBundle() {
        let skill = loadSkill(.toPrd)
        #expect(skill.name == "to-prd")
        #expect(skill.fileUrl.path.hasSuffix("skills/to-prd/SKILL.md"))
        #expect(skill.folderUrl == skill.fileUrl.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: skill.fileUrl.path))
    }

    // MARK: - The directed Turn

    @Test
    func generateRunsOneDirectedTurnWithSkillSummaryInputAndReadOnlyMode() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let summaryPath = workflowDirectory
            .appending(path: "phases/design", directoryHint: .isDirectory)
            .appending(path: "summary.md")
            .path
        try Self.seedCompletedDesignPhase(database, summaryPath: summaryPath)
        let skill = loadSkill(.toPrd)
        let captured = LockIsolated<StartRequest?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return try await Self.startSession(for: request, id: UUID(100), finalAnswer: "# PRD")
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.generate()
        await model.runTask?.value

        let request = try #require(captured.value)
        #expect(request.mode == .readOnly)
        #expect(request.worktree == URL(fileURLWithPath: "/repo"))
        #expect(request.workflowID == UUID(-1))
        #expect(request.kind == .prd)
        #expect(request.skillFiles == [skill.fileUrl])
        #expect(request.addDirs == [skill.folderUrl])
        #expect(request.prompt == PRDModel.directedPrompt(summaryPath: summaryPath))
        // The summary is an input: only its directory is exposed to the Harness, not the whole
        // Workflow directory (which holds the database).
        let inputs = try #require(request.inputs)
        #expect(inputs.root == URL(fileURLWithPath: summaryPath).deletingLastPathComponent())
        #expect(inputs.relativePaths == ["summary.md"])
    }

    @Test
    func generateWritesArtifactAndCompletesPhase() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedCompletedDesignPhase(database, summaryPath: "/wf/phases/design/summary.md")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                try await Self.startSession(
                    for: request, id: UUID(100), finalAnswer: "# PRD\n\nThe requirements."
                )
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.generate()
        await model.runTask?.value

        let prdURL = workflowDirectory
            .appending(path: "phases/prd", directoryHint: .isDirectory)
            .appending(path: "prd.md")
        #expect(try String(contentsOf: prdURL, encoding: .utf8) == "# PRD\n\nThe requirements.")
        #expect(model.engine.errorText == nil)
        #expect(!model.engine.isRunning)

        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("prd") }.fetchOne(db)
        }
        #expect(phase?.workflowID == UUID(-1))
        #expect(phase?.status == "complete")
        #expect(phase?.artifactPath == prdURL.path)

        // The saved confirmation is derived from the completed `prd` phase row, so it also shows
        // again when the window is reopened.
        try await model.$prdPhase.load()
        #expect(model.prdSavedURL == prdURL)
        #expect(!model.isGenerateAvailable)
        #expect(model.isRegenerateAvailable)
    }

    // MARK: - Regenerate

    @Test
    func regenerateResumesExistingSessionWithRevisedSummaryInstructionAndInput() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let summaryPath = "/wf/phases/design/summary.md"
        try Self.seedCompletedDesignPhase(database, summaryPath: summaryPath)
        // The completed Phase and its Session pre-exist the model, as after closing and reopening
        // the window; the engine rediscovers the Session, so regenerate resumes it.
        let sessionID = UUID(100)
        try Self.seedCompletedPRDPhase(database, sessionID: sessionID, artifactPath: "/wf/phases/prd/prd.md")
        let started = LockIsolated(false)
        let captured = LockIsolated<SendRequest?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                started.setValue(true)
                return try await Self.startSession(for: request, id: UUID(101), finalAnswer: "")
            }
            $0.agentClient.send = { @Sendable request in
                captured.setValue(request)
                return try await Self.resumeSession(for: request, turnID: UUID(201), finalAnswer: "# PRD v2")
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }
        try await model.$prdPhase.load()
        #expect(model.isRegenerateAvailable)

        model.regenerate()
        await model.runTask?.value

        // Resumed, not restarted: a fresh Session would break one-Session-per-(Workflow, kind).
        #expect(!started.value)
        let request = try #require(captured.value)
        #expect(request.session.id.rawValue == sessionID)
        // The (possibly edited) summary is re-attached, and the instruction flags the revision.
        #expect(request.prompt == PRDModel.regeneratePrompt(summaryPath: summaryPath))
        let inputs = try #require(request.inputs)
        #expect(inputs.root == URL(fileURLWithPath: summaryPath).deletingLastPathComponent())
        #expect(inputs.relativePaths == ["summary.md"])
        #expect(model.engine.errorText == nil)
        #expect(!model.engine.isRunning)
    }

    @Test
    func regenerateOverwritesSameArtifactAndUpdatesSamePhaseRow() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedCompletedDesignPhase(database, summaryPath: "/wf/phases/design/summary.md")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                try await Self.startSession(for: request, id: UUID(100), finalAnswer: "# PRD v1")
            }
            $0.agentClient.send = { @Sendable request in
                try await Self.resumeSession(for: request, turnID: UUID(201), finalAnswer: "# PRD v2")
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.generate()
        await model.runTask?.value
        try await model.$prdPhase.load()
        let firstRowID = try #require(model.prdPhase?.id)

        model.regenerate()
        await model.runTask?.value

        let prdURL = workflowDirectory
            .appending(path: "phases/prd", directoryHint: .isDirectory)
            .appending(path: "prd.md")
        #expect(try String(contentsOf: prdURL, encoding: .utf8) == "# PRD v2")
        #expect(model.engine.errorText == nil)

        // One current PRD: the same file and the same Phase row, not a second of either.
        let phases = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("prd") }.fetchAll(db)
        }
        #expect(phases.count == 1)
        #expect(phases.first?.id == firstRowID)
        #expect(phases.first?.status == "complete")
        #expect(phases.first?.artifactPath == prdURL.path)
    }

    @Test
    func generateFailsWhenDesignSummaryIsMissing() async throws {
        let database = try Self.makeDatabase()
        let started = LockIsolated(false)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                started.setValue(true)
                return Session(
                    id: Session.ID(rawValue: UUID(100)), worktree: request.worktree,
                    mode: request.mode, kind: request.kind
                )
            }
        } operation: {
            Self.makeModel(workflowDirectory: Self.makeWorkflowDirectory(), database: database)
        }

        model.generate()
        await model.runTask?.value

        #expect(!started.value)
        #expect(model.engine.errorText != nil)
        #expect(!model.engine.isRunning)
    }

    @Test
    func isIdleWithGenerateAvailableBeforeAnyGeneration() async throws {
        let database = try Self.makeDatabase()

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            Self.makeModel(workflowDirectory: Self.makeWorkflowDirectory(), database: database)
        }

        #expect(model.isIdle)
        #expect(model.isGenerateAvailable)
        #expect(!model.isRegenerateAvailable)
        #expect(model.prdSavedURL == nil)
    }

    // MARK: - Helpers

    @MainActor
    private static func makeModel(
        workflowDirectory: URL,
        database: any DatabaseWriter
    ) -> PRDModel {
        PRDModel(
            worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
            workflowDirectory: workflowDirectory, database: database
        )
    }

    /// Stands in for the live client's `start`: records the Session and its one Turn (with the
    /// final answer the projector would have written) and returns the started Session.
    private static func startSession(
        for request: StartRequest, id: UUID, finalAnswer: String
    ) async throws -> Session {
        try await request.database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: id, workflowID: request.workflowID, worktreePath: request.worktree.path,
                    mode: request.mode.rawValue, kind: request.kind.rawValue,
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            try TurnRow.insert {
                TurnRow(
                    id: UUID(200), sessionID: id, userPrompt: request.prompt,
                    finalAnswer: finalAnswer, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
        return Session(
            id: Session.ID(rawValue: id),
            worktree: request.worktree,
            mode: request.mode,
            kind: request.kind,
            skillFiles: request.skillFiles,
            addDirs: request.addDirs
        )
    }

    /// Stands in for the live client's `send`: appends the resumed Turn (with the final answer the
    /// projector would have written, dated after the initial Turn's) and returns the same Session.
    private static func resumeSession(
        for request: SendRequest, turnID: UUID, finalAnswer: String
    ) async throws -> Session {
        try await request.database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: turnID, sessionID: request.session.id.rawValue, userPrompt: request.prompt,
                    finalAnswer: finalAnswer,
                    createdAt: fixedDate.addingTimeInterval(1), updatedAt: fixedDate
                )
            }
            .execute(db)
        }
        return request.session
    }

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRDTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }

    private static func makeWorkflowDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PRDTests-WF-\(UUID().uuidString)", isDirectory: true)
    }

    private static func seedCompletedDesignPhase(
        _ database: any DatabaseWriter, summaryPath: String
    ) throws {
        let workflowID = UUID(-1)
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try PhaseRow.insert {
                PhaseRow(
                    id: UUID(-2), workflowID: workflowID, kind: "design", status: "complete",
                    artifactPath: summaryPath, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    /// Seeds the persisted state of an already-completed PRD Phase — the prior `prd` Session and the
    /// completed `prd` phase row — as found when the window is reopened.
    private static func seedCompletedPRDPhase(
        _ database: any DatabaseWriter, sessionID: UUID, artifactPath: String
    ) throws {
        let workflowID = UUID(-1)
        try database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: sessionID, workflowID: workflowID, worktreePath: "/repo", mode: "readOnly",
                    kind: "prd", createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            try PhaseRow.insert {
                PhaseRow(
                    id: UUID(-3), workflowID: workflowID, kind: "prd", status: "complete",
                    artifactPath: artifactPath, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }
}
