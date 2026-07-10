import Agent
import Dependencies
import Foundation
import Skills
import SQLiteData
import Store
import Testing

@testable import Design

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
private let mcpServerCommand = "/repo/.build/hercules"

@MainActor
@Suite("DesignModel")
struct DesignModelTests {

    // MARK: - Engine wiring

    @Test
    func firstSubmitStartsReadOnlySessionUnderSkill() async throws {
        let database = try Self.makeDatabase()
        // The Skill is loaded from the Skills bundle at init, not injected.
        let skill = loadSkill(.grillMe)
        let captured = LockIsolated<StartRequest?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return Session(
                    id: Session.ID(rawValue: UUID(100)),
                    worktree: request.worktree,
                    mode: request.mode,
                    kind: request.kind,
                    skillFiles: request.skillFiles,
                    addDirs: request.addDirs
                )
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(),
                mcpServerCommand: mcpServerCommand, database: database
            )
        }

        model.engine.draftText = "What are we building?"
        model.engine.submit()
        await model.engine.runTask?.value

        let request = try #require(captured.value)
        #expect(request.mode == .readOnly)
        #expect(request.worktree == URL(fileURLWithPath: "/repo"))
        #expect(request.workflowID == UUID(-1))
        #expect(request.skillFiles == [skill.fileUrl])
        #expect(request.addDirs == [skill.folderUrl])
    }

    // MARK: - Generating the design summary

    @Test
    func generateSummaryIsUnavailableUntilSessionStarts() async throws {
        let database = try Self.makeDatabase()
        let model = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                Session(id: Session.ID(rawValue: UUID(100)), worktree: request.worktree, mode: request.mode, kind: request.kind)
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(),
                mcpServerCommand: mcpServerCommand, database: database
            )
        }
        #expect(!model.isGenerateSummaryAvailable)

        model.engine.draftText = "kick off"
        model.engine.submit()
        await model.engine.runTask?.value

        #expect(model.isGenerateSummaryAvailable)
    }

    @Test
    func generateSummaryWritesArtifactAndCompletesPhase() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let sessionID = UUID(100)
        try Self.seedSession(database, sessionID: sessionID)
        let turns = LockIsolated(0)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                Session(id: Session.ID(rawValue: sessionID), worktree: request.worktree, mode: request.mode, kind: request.kind)
            }
            $0.agentClient.send = { @Sendable request in
                // Each Turn needs a distinct id; the Session is rediscovered, so the kick-off and the
                // finalization both resume it (two sends).
                let n = turns.withValue { value -> Int in defer { value += 1 }; return value }
                // Simulate the write_artifact tool: the finalization Turn carries the writer as a per-turn
                // override, so only it persists the file; the kick-off Turn does not.
                if let path = Self.artifactPath(in: request.mcpServers) {
                    try Self.writeArtifactFile("# Design\n\nThe plan.", toPath: path)
                }
                try await request.database.write { db in
                    try TurnRow.insert {
                        TurnRow(
                            id: UUID(200 + n), sessionID: sessionID, userPrompt: request.prompt,
                            finalAnswer: "done",
                            createdAt: fixedDate.addingTimeInterval(TimeInterval(n)), updatedAt: fixedDate
                        )
                    }
                    .execute(db)
                }
                return request.session
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: workflowDirectory,
                mcpServerCommand: mcpServerCommand, database: database
            )
        }

        model.engine.draftText = "kick off"
        model.engine.submit()
        await model.engine.runTask?.value

        model.generateSummary()
        await model.runTask?.value

        let summaryURL = workflowDirectory
            .appending(path: "phases/design", directoryHint: .isDirectory)
            .appending(path: "summary.md")
        #expect(model.summarySavedURL == summaryURL)
        #expect(try String(contentsOf: summaryURL, encoding: .utf8) == "# Design\n\nThe plan.")
        #expect(model.engine.errorText == nil)
        #expect(!model.engine.isRunning)

        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("design") }.fetchOne(db)
        }
        #expect(phase?.workflowID == UUID(-1))
        #expect(phase?.status == "complete")
        #expect(phase?.artifactPath == summaryURL.path)
    }

    @Test
    func reRunningSummaryOverwritesFileAndUpdatesSamePhaseRow() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let sessionID = UUID(100)
        try Self.seedSession(database, sessionID: sessionID)
        let calls = LockIsolated(0)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                Session(id: Session.ID(rawValue: sessionID), worktree: request.worktree, mode: request.mode, kind: request.kind)
            }
            $0.agentClient.send = { @Sendable request in
                let n = calls.withValue { value -> Int in
                    defer { value += 1 }
                    return value
                }
                // Both finalization Turns carry the writer and overwrite the same file with fresh content;
                // the kick-off Turn (no writer) leaves it alone.
                if let path = Self.artifactPath(in: request.mcpServers) {
                    try Self.writeArtifactFile(n == 1 ? "# First" : "# Second", toPath: path)
                }
                try await request.database.write { db in
                    try TurnRow.insert {
                        TurnRow(
                            id: UUID(200 + n), sessionID: sessionID, userPrompt: request.prompt,
                            finalAnswer: "done",
                            createdAt: fixedDate.addingTimeInterval(TimeInterval(n)), updatedAt: fixedDate
                        )
                    }
                    .execute(db)
                }
                return request.session
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: workflowDirectory,
                mcpServerCommand: mcpServerCommand, database: database
            )
        }

        model.engine.draftText = "kick off"
        model.engine.submit()
        await model.engine.runTask?.value

        model.generateSummary()
        await model.runTask?.value
        model.generateSummary()
        await model.runTask?.value

        let summaryURL = workflowDirectory
            .appending(path: "phases/design", directoryHint: .isDirectory)
            .appending(path: "summary.md")
        #expect(try String(contentsOf: summaryURL, encoding: .utf8) == "# Second")

        let designPhases = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("design") }.fetchAll(db)
        }
        #expect(designPhases.count == 1)
        #expect(designPhases.first?.status == "complete")
        #expect(designPhases.first?.artifactPath == summaryURL.path)
    }

    @Test
    func generateSummaryDoesNotCompletePhaseWhenNothingWritten() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let sessionID = UUID(100)
        try Self.seedSession(database, sessionID: sessionID)
        let turns = LockIsolated(0)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                Session(id: Session.ID(rawValue: sessionID), worktree: request.worktree, mode: request.mode, kind: request.kind)
            }
            $0.agentClient.send = { @Sendable request in
                // The finalization Turn returns without ever calling write_artifact — no file appears.
                let n = turns.withValue { value -> Int in defer { value += 1 }; return value }
                try await request.database.write { db in
                    try TurnRow.insert {
                        TurnRow(
                            id: UUID(200 + n), sessionID: sessionID, userPrompt: request.prompt,
                            finalAnswer: "I forgot to save.",
                            createdAt: fixedDate.addingTimeInterval(TimeInterval(n)), updatedAt: fixedDate
                        )
                    }
                    .execute(db)
                }
                return request.session
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: workflowDirectory,
                mcpServerCommand: mcpServerCommand, database: database
            )
        }

        model.engine.draftText = "kick off"
        model.engine.submit()
        await model.engine.runTask?.value

        model.generateSummary()
        await model.runTask?.value

        // No file was written, the Phase is not completed, and an error is surfaced.
        let summaryURL = workflowDirectory
            .appending(path: "phases/design", directoryHint: .isDirectory)
            .appending(path: "summary.md")
        #expect(!FileManager.default.fileExists(atPath: summaryURL.path))
        #expect(model.summarySavedURL == nil)
        #expect(model.engine.errorText != nil)
        #expect(!model.engine.isRunning)

        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("design") }.fetchOne(db)
        }
        #expect(phase == nil)
    }

    @Test
    func savedSummaryBannerSurvivesRelaunch() async throws {
        // Simulates reopening the app: the model is constructed fresh against a database that already
        // holds a completed design Phase. The saved-summary confirmation must come back from the row,
        // not depend on an in-memory flag set during this session.
        let database = try Self.makeDatabase()
        let summaryPath = "/wf/phases/design/summary.md"
        try Self.seedCompletedDesignPhase(database, summaryPath: summaryPath)

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(),
                mcpServerCommand: mcpServerCommand, database: database
            )
        }
        try await model.$designPhase.load()

        #expect(model.summarySavedURL == URL(fileURLWithPath: summaryPath))

        // Sending a new message dismisses the banner without forgetting the persisted summary.
        model.engine.onSend?()
        #expect(model.summarySavedURL == nil)
    }

    // MARK: - Helpers

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }

    private static func makeWorkflowDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignTests-WF-\(UUID().uuidString)", isDirectory: true)
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

    /// The `--artifact-path` carried by the write_artifact server on a Turn, or `nil` when the Turn has
    /// no writer attached (e.g. the kick-off Turn, or a Turn with the empty override). `nonisolated` so
    /// the `@Sendable` agent-client closures can call it off the main actor.
    nonisolated private static func artifactPath(in servers: [MCPServer]?) -> String? {
        guard let servers else { return nil }
        for server in servers where server.tools.contains("write_artifact") {
            if let index = server.args.firstIndex(of: "--artifact-path"), index + 1 < server.args.count {
                return server.args[index + 1]
            }
        }
        return nil
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

    private static func seedSession(_ database: any DatabaseWriter, sessionID: UUID) throws {
        let workflowID = UUID(-1)
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try SessionRow.insert {
                SessionRow(
                    id: sessionID, workflowID: workflowID, worktreePath: "/repo", mode: "readOnly",
                    kind: "design", createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }
}
