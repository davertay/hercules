import Agent
import Dependencies
import Foundation
import Skills
import SQLiteData
import Store
import Testing

@testable import PRD

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
private let mcpServerCommand = "/repo/.build/hercules"

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
                return try await Self.startSession(for: request, id: UUID(100), writes: "# PRD")
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
        // Only the summary's directory is exposed, not the whole Workflow directory.
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
                    for: request, id: UUID(100), writes: "# PRD\n\nThe requirements."
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

        // The saved confirmation is derived from the row, so it shows again on reopen.
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
        // The Phase and Session pre-exist the model (as after a reopen), so the engine rediscovers it.
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
                return try await Self.startSession(for: request, id: UUID(101), writes: "")
            }
            $0.agentClient.send = { @Sendable request in
                captured.setValue(request)
                return try await Self.resumeSession(for: request, turnID: UUID(201), writes: "# PRD v2")
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
                try await Self.startSession(for: request, id: UUID(100), writes: "# PRD v1")
            }
            $0.agentClient.send = { @Sendable request in
                try await Self.resumeSession(for: request, turnID: UUID(201), writes: "# PRD v2")
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
    func generateDoesNotCompletePhaseWhenNothingWritten() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedCompletedDesignPhase(database, summaryPath: "/wf/phases/design/summary.md")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                // The Generate Turn returns without ever calling write_artifact — no file appears.
                try await request.database.write { db in
                    try SessionRow.insert {
                        SessionRow(
                            id: UUID(100), workflowID: request.workflowID,
                            worktreePath: request.worktree.path, mode: request.mode.rawValue,
                            kind: request.kind.rawValue, createdAt: fixedDate, updatedAt: fixedDate
                        )
                    }
                    .execute(db)
                    try TurnRow.insert {
                        TurnRow(
                            id: UUID(200), sessionID: UUID(100), userPrompt: request.prompt,
                            finalAnswer: "I forgot to save.", createdAt: fixedDate, updatedAt: fixedDate
                        )
                    }
                    .execute(db)
                }
                return Session(
                    id: Session.ID(rawValue: UUID(100)), worktree: request.worktree,
                    mode: request.mode, kind: request.kind
                )
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.generate()
        await model.runTask?.value

        // No file was written, the Phase is not completed, and an error is surfaced.
        let prdURL = workflowDirectory
            .appending(path: "phases/prd", directoryHint: .isDirectory)
            .appending(path: "prd.md")
        #expect(!FileManager.default.fileExists(atPath: prdURL.path))
        #expect(model.prdSavedURL == nil)
        #expect(model.engine.errorText != nil)
        #expect(!model.engine.isRunning)

        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("prd") }.fetchOne(db)
        }
        #expect(phase == nil)
    }

    // MARK: - Skip

    @Test
    func skipCompletesThePhaseWithNoArtifactAndStartsNoSession() async throws {
        let database = try Self.makeDatabase()
        try Self.seedCompletedDesignPhase(database, summaryPath: "/wf/phases/design/summary.md")
        let started = LockIsolated(false)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                started.setValue(true)
                return try await Self.startSession(for: request, id: UUID(100), writes: "")
            }
        } operation: {
            Self.makeModel(workflowDirectory: Self.makeWorkflowDirectory(), database: database)
        }

        model.skip()
        await model.runTask?.value

        // No agent ran and no PRD was written.
        #expect(!started.value)
        #expect(model.engine.errorText == nil)

        // The Phase is recorded complete with a null Artifact path — which still unlocks the next Phase.
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("prd") }.fetchOne(db)
        }
        #expect(phase?.status == "complete")
        #expect(phase?.artifactPath == nil)

        // The model reflects the terminal skipped state: complete, no Artifact, no further actions.
        try await model.$prdPhase.load()
        #expect(model.isComplete)
        #expect(model.isSkipped)
        #expect(model.prdSavedURL == nil)
        #expect(!model.isGenerateAvailable)
        #expect(!model.isRegenerateAvailable)
    }

    @Test
    func unskipReversesASkipBackToTheIdleGenerateState() async throws {
        let database = try Self.makeDatabase()
        try Self.seedCompletedDesignPhase(database, summaryPath: "/wf/phases/design/summary.md")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
        } operation: {
            Self.makeModel(workflowDirectory: Self.makeWorkflowDirectory(), database: database)
        }

        model.skip()
        try await model.$prdPhase.load()
        #expect(model.isSkipped)

        model.unskip()
        try await model.$prdPhase.load()

        // The Phase reads as idle again, with the generate action restored.
        #expect(!model.isComplete)
        #expect(!model.isSkipped)
        #expect(model.isGenerateAvailable)
        #expect(model.engine.errorText == nil)

        // The row is soft-deleted, not hard-deleted, so it no longer counts as a completed Phase.
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("prd") }.fetchOne(db)
        }
        #expect(phase?.isDeleted == true)
    }

    @Test
    func generateAfterUnskipResurrectsTheRowAndCompletesNormally() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedCompletedDesignPhase(database, summaryPath: "/wf/phases/design/summary.md")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                try await Self.startSession(for: request, id: UUID(100), writes: "# PRD")
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.skip()
        try await model.$prdPhase.load()
        model.unskip()
        try await model.$prdPhase.load()

        model.generate()
        await model.runTask?.value
        try await model.$prdPhase.load()

        let prdURL = workflowDirectory
            .appending(path: "phases/prd", directoryHint: .isDirectory)
            .appending(path: "prd.md")
        #expect(model.prdSavedURL == prdURL)
        #expect(model.isComplete)
        #expect(!model.isSkipped)

        // The same row is reused and resurrected — one PRD Phase row, no longer soft-deleted.
        let phases = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("prd") }.fetchAll(db)
        }
        #expect(phases.count == 1)
        #expect(phases.first?.isDeleted == false)
        #expect(phases.first?.artifactPath == prdURL.path)
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
            workflowDirectory: workflowDirectory,
            mcpServerCommand: mcpServerCommand, database: database
        )
    }

    /// Stands in for the live client's `start`, recording the Session and its one Turn. The
    /// `write_artifact` writer is pinned on the PRD Session, so the first (Generate) Turn carries it in
    /// `request.mcpServers`; this simulates that tool call by writing `writes` to its `--artifact-path`.
    /// The returned Session carries the pinned servers so a later resume re-passes them (as the live
    /// client does).
    private static func startSession(
        for request: StartRequest, id: UUID, writes: String
    ) async throws -> Session {
        if let path = artifactPath(in: request.mcpServers) {
            try writeArtifactFile(writes, toPath: path)
        }
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
                    finalAnswer: "done", createdAt: fixedDate, updatedAt: fixedDate
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
            addDirs: request.addDirs,
            mcpServers: request.mcpServers
        )
    }

    /// Stands in for the live client's `send`, appending the resumed Turn dated after the initial one. On
    /// a resume the writer is re-passed via the Session's pinned servers (the per-Turn override is `nil`
    /// for PRD), so this simulates Regenerate rewriting the same file with `writes`.
    private static func resumeSession(
        for request: SendRequest, turnID: UUID, writes: String
    ) async throws -> Session {
        if let path = artifactPath(in: request.session.mcpServers) {
            try writeArtifactFile(writes, toPath: path)
        }
        try await request.database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: turnID, sessionID: request.session.id.rawValue, userPrompt: request.prompt,
                    finalAnswer: "done",
                    createdAt: fixedDate.addingTimeInterval(1), updatedAt: fixedDate
                )
            }
            .execute(db)
        }
        return request.session
    }

    /// Stands in for the write_artifact MCP child: create intermediate directories and write the file.
    /// `nonisolated` so the `@Sendable` agent-client closures can call it off the main actor.
    nonisolated private static func writeArtifactFile(_ markdown: String, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The `--artifact-path` carried by the write_artifact server, or `nil` when none is attached.
    /// `nonisolated` so the `@Sendable` agent-client closures can call it off the main actor.
    nonisolated private static func artifactPath(in servers: [MCPServer]?) -> String? {
        guard let servers else { return nil }
        for server in servers where server.tools.contains("write_artifact") {
            if let index = server.args.firstIndex(of: "--artifact-path"), index + 1 < server.args.count {
                return server.args[index + 1]
            }
        }
        return nil
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

    /// Seeds an already-completed PRD Phase — its `prd` Session and completed phase row.
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
