import Agent
import Dependencies
import Foundation
import SQLiteData
import Store
import Testing

@testable import Design

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
@Suite("DesignModel")
struct DesignModelTests {

    // MARK: - Conversation rendering from the database

    @Test
    func messagesAreBuiltFromObservedTurnsAndBlocks() async throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(-2)
        try Self.seedSession(database, sessionID: sessionID)
        try await database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-10), sessionID: sessionID, userPrompt: "hello",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            try ContentBlockRow.insert {
                ContentBlockRow(
                    id: UUID(-11), turnID: UUID(-10), position: 0, role: "assistant", kind: "text",
                    text: "Hi there", createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-20), sessionID: sessionID, userPrompt: "more", isError: true,
                    createdAt: fixedDate.addingTimeInterval(1), updatedAt: fixedDate
                )
            }
            .execute(db)
        }

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(), database: database
            )
        }
        try await model.$conversation.load()

        #expect(
            model.messages == [
                DesignModel.Message(id: "\(UUID(-10).uuidString)/user", kind: .user, text: "hello"),
                DesignModel.Message(id: "\(UUID(-10).uuidString)/0", kind: .assistant, text: "Hi there"),
                DesignModel.Message(id: "\(UUID(-20).uuidString)/user", kind: .user, text: "more"),
                DesignModel.Message(id: "\(UUID(-20).uuidString)/assistant", kind: .assistant, text: "Turn failed.", isError: true),
            ]
        )
    }

    @Test
    func toolCallTimelineRendersThinkingToolUseAndToolResultDistinctly() async throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(-2)
        try Self.seedSession(database, sessionID: sessionID)
        try await database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-10), sessionID: sessionID, userPrompt: "find it",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            try ContentBlockRow.insert {
                ContentBlockRow(
                    id: UUID(-11), turnID: UUID(-10), position: 0, role: "assistant", kind: "thinking",
                    text: "Let me look.", createdAt: fixedDate, updatedAt: fixedDate
                )
                ContentBlockRow(
                    id: UUID(-12), turnID: UUID(-10), position: 1, role: "assistant", kind: "tool_use",
                    text: #"{"path":"README.md"}"#, toolName: "Read", createdAt: fixedDate, updatedAt: fixedDate
                )
                ContentBlockRow(
                    id: UUID(-13), turnID: UUID(-10), position: 2, role: "user", kind: "tool_result",
                    text: "file contents", createdAt: fixedDate, updatedAt: fixedDate
                )
                ContentBlockRow(
                    id: UUID(-14), turnID: UUID(-10), position: 3, role: "assistant", kind: "text",
                    text: "Found it.", createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(), database: database
            )
        }
        try await model.$conversation.load()

        #expect(
            model.messages == [
                DesignModel.Message(id: "\(UUID(-10).uuidString)/user", kind: .user, text: "find it"),
                DesignModel.Message(id: "\(UUID(-10).uuidString)/0", kind: .thinking, text: "Let me look."),
                DesignModel.Message(id: "\(UUID(-10).uuidString)/1", kind: .toolUse, text: #"{"path":"README.md"}"#, toolName: "Read"),
                DesignModel.Message(id: "\(UUID(-10).uuidString)/2", kind: .toolResult, text: "file contents"),
                DesignModel.Message(id: "\(UUID(-10).uuidString)/3", kind: .assistant, text: "Found it."),
            ]
        )
    }

    @Test
    func isIntakeUntilThereAreMessages() async throws {
        let database = try Self.makeDatabase()
        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(), database: database
            )
        }
        #expect(model.isIntake)

        let sessionID = UUID(-2)
        try Self.seedSession(database, sessionID: sessionID)
        try await database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-10), sessionID: sessionID, userPrompt: "hello",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
        try await model.$conversation.load()

        #expect(!model.isIntake)
    }

    // MARK: - Starting and resuming the Session

    @Test
    func firstSubmitStartsReadOnlySessionUnderSkill() async throws {
        let database = try Self.makeDatabase()
        let skillURL = URL(fileURLWithPath: "/bundle/Resources/grill-me/grill-me.md")
        let captured = LockIsolated<StartRequest?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.designSkillFile = skillURL
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

        model.draftText = "What are we building?"
        model.submit()
        await model.runTask?.value

        let request = try #require(captured.value)
        #expect(request.prompt == "What are we building?")
        #expect(request.mode == .readOnly)
        #expect(request.worktree == URL(fileURLWithPath: "/repo"))
        #expect(request.workflowID == UUID(-1))
        #expect(request.skillFiles == [skillURL])
        #expect(request.addDirs == [skillURL.deletingLastPathComponent()])
        #expect(model.draftText.isEmpty)
        #expect(!model.isRunning)
        #expect(model.errorText == nil)
    }

    @Test
    func followUpSubmitResumesSameSession() async throws {
        let database = try Self.makeDatabase()
        let startedSession = Session(
            id: Session.ID(rawValue: UUID(100)),
            worktree: URL(fileURLWithPath: "/repo"),
            mode: .readOnly
        )
        let resumed = LockIsolated<SendRequest?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable _ in startedSession }
            $0.agentClient.send = { @Sendable request in
                resumed.setValue(request)
                return request.session
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(), database: database
            )
        }

        model.draftText = "first"
        model.submit()
        await model.runTask?.value

        model.draftText = "second"
        model.submit()
        await model.runTask?.value

        let request = try #require(resumed.value)
        #expect(request.prompt == "second")
        #expect(request.session.id == startedSession.id)
    }

    @Test
    func startFailureSurfacesAsErrorText() async throws {
        let database = try Self.makeDatabase()
        let model = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable _ in
                throw AgentError.harnessNotFound(triedPath: URL(fileURLWithPath: "/no/claude"))
            }
        } operation: {
            DesignModel(
                worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
                workflowDirectory: Self.makeWorkflowDirectory(), database: database
            )
        }

        model.draftText = "hi"
        model.submit()
        await model.runTask?.value

        #expect(model.errorText != nil)
        #expect(!model.isRunning)
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

        model.draftText = "kick off"
        model.submit()
        await model.runTask?.value

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

        model.draftText = "kick off"
        model.submit()
        await model.runTask?.value

        model.generateSummary()
        await model.runTask?.value

        let summaryURL = workflowDirectory
            .appending(path: "phases/design", directoryHint: .isDirectory)
            .appending(path: "summary.md")
        #expect(model.summarySavedURL == summaryURL)
        #expect(try String(contentsOf: summaryURL, encoding: .utf8) == "# Design\n\nThe plan.")
        #expect(model.errorText == nil)
        #expect(!model.isRunning)

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

        model.draftText = "kick off"
        model.submit()
        await model.runTask?.value

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
