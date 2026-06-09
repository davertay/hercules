import Agent
import Dependencies
import Foundation
import SQLiteData
import Store
import Testing

@testable import Chat

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
@Suite("ChatEngine")
struct ChatEngineTests {

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

        let engine = Self.makeEngine(database: database)
        try await engine.$conversation.load()

        #expect(
            engine.messages == [
                ChatEngine.Message(id: "\(UUID(-10).uuidString)/user", kind: .user, text: "hello"),
                ChatEngine.Message(id: "\(UUID(-10).uuidString)/0", kind: .assistant, text: "Hi there"),
                ChatEngine.Message(id: "\(UUID(-20).uuidString)/user", kind: .user, text: "more"),
                ChatEngine.Message(id: "\(UUID(-20).uuidString)/assistant", kind: .assistant, text: "Turn failed.", isError: true),
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

        let engine = Self.makeEngine(database: database)
        try await engine.$conversation.load()

        #expect(
            engine.messages == [
                ChatEngine.Message(id: "\(UUID(-10).uuidString)/user", kind: .user, text: "find it"),
                ChatEngine.Message(id: "\(UUID(-10).uuidString)/0", kind: .thinking, text: "Let me look."),
                ChatEngine.Message(id: "\(UUID(-10).uuidString)/1", kind: .toolUse, text: #"{"path":"README.md"}"#, toolName: "Read"),
                ChatEngine.Message(id: "\(UUID(-10).uuidString)/2", kind: .toolResult, text: "file contents"),
                ChatEngine.Message(id: "\(UUID(-10).uuidString)/3", kind: .assistant, text: "Found it."),
            ]
        )
    }

    @Test
    func isIntakeUntilThereAreMessages() async throws {
        let database = try Self.makeDatabase()
        let engine = Self.makeEngine(database: database)
        #expect(engine.isIntake)

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
        try await engine.$conversation.load()

        #expect(!engine.isIntake)
    }

    // MARK: - Starting and resuming the Session

    @Test
    func firstSubmitStartsSessionWithConfiguredParameters() async throws {
        let database = try Self.makeDatabase()
        let skillFiles = [URL(fileURLWithPath: "/skill/grill-me.md")]
        let addDirs = [URL(fileURLWithPath: "/skill")]
        let captured = LockIsolated<StartRequest?>(nil)

        let engine = withDependencies {
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
            ChatEngine(
                worktree: URL(fileURLWithPath: "/repo"), mode: .readOnly, workflowID: UUID(-1),
                skillFiles: skillFiles, addDirs: addDirs, database: database
            )
        }

        engine.draftText = "What are we building?"
        engine.submit()
        await engine.runTask?.value

        let request = try #require(captured.value)
        #expect(request.prompt == "What are we building?")
        #expect(request.mode == .readOnly)
        #expect(request.worktree == URL(fileURLWithPath: "/repo"))
        #expect(request.workflowID == UUID(-1))
        #expect(request.skillFiles == skillFiles)
        #expect(request.addDirs == addDirs)
        #expect(engine.draftText.isEmpty)
        #expect(!engine.isRunning)
        #expect(engine.errorText == nil)
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

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable _ in startedSession }
            $0.agentClient.send = { @Sendable request in
                resumed.setValue(request)
                return request.session
            }
        } operation: {
            Self.makeEngine(database: database)
        }

        engine.draftText = "first"
        engine.submit()
        await engine.runTask?.value

        engine.draftText = "second"
        engine.submit()
        await engine.runTask?.value

        let request = try #require(resumed.value)
        #expect(request.prompt == "second")
        #expect(request.session.id == startedSession.id)
    }

    @Test
    func startFailureSurfacesAsErrorText() async throws {
        let database = try Self.makeDatabase()
        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable _ in
                throw AgentError.harnessNotFound(triedPath: URL(fileURLWithPath: "/no/claude"))
            }
        } operation: {
            Self.makeEngine(database: database)
        }

        engine.draftText = "hi"
        engine.submit()
        await engine.runTask?.value

        #expect(engine.errorText != nil)
        #expect(!engine.isRunning)
    }

    // MARK: - Helpers

    private static func makeEngine(database: any DatabaseWriter) -> ChatEngine {
        withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ChatEngine(
                worktree: URL(fileURLWithPath: "/repo"), mode: .readOnly, workflowID: UUID(-1),
                database: database
            )
        }
    }

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
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
