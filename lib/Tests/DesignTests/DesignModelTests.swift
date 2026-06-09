import Agent
import Dependencies
import Foundation
import Material
import SQLiteData
import Store
import Testing

@testable import Design

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
@Suite("DesignModel")
struct DesignModelTests {

    // MARK: - Engine wiring

    @Test
    func firstSubmitStartsReadOnlySessionUnderSkill() async throws {
        let database = try Self.makeDatabase()
        // The Skill is loaded from the Material bundle at init, not injected.
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
                    skillFiles: request.skillFiles,
                    addDirs: request.addDirs
                )
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(), database: database
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
                Session(id: Session.ID(rawValue: UUID(100)), worktree: request.worktree, mode: request.mode)
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(), database: database
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

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                Session(id: Session.ID(rawValue: sessionID), worktree: request.worktree, mode: request.mode)
            }
            $0.agentClient.send = { @Sendable request in
                try await request.database.write { db in
                    try TurnRow.insert {
                        TurnRow(
                            id: UUID(200), sessionID: sessionID, userPrompt: request.prompt,
                            finalAnswer: "# Design\n\nThe plan.", createdAt: fixedDate, updatedAt: fixedDate
                        )
                    }
                    .execute(db)
                }
                return request.session
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: workflowDirectory, database: database
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
                Session(id: Session.ID(rawValue: sessionID), worktree: request.worktree, mode: request.mode)
            }
            $0.agentClient.send = { @Sendable request in
                let n = calls.withValue { value -> Int in
                    defer { value += 1 }
                    return value
                }
                try await request.database.write { db in
                    try TurnRow.insert {
                        TurnRow(
                            id: UUID(200 + n), sessionID: sessionID, userPrompt: request.prompt,
                            finalAnswer: n == 0 ? "# First" : "# Second",
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
                workflowDirectory: workflowDirectory, database: database
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
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }
}
