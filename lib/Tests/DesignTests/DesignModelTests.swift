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
            DesignModel(worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1), database: database)
        }
        try await model.$conversation.load()

        #expect(
            model.messages == [
                DesignModel.Message(id: "\(UUID(-10).uuidString)/user", role: .user, text: "hello", isError: false),
                DesignModel.Message(id: "\(UUID(-10).uuidString)/assistant", role: .assistant, text: "Hi there", isError: false),
                DesignModel.Message(id: "\(UUID(-20).uuidString)/user", role: .user, text: "more", isError: false),
                DesignModel.Message(id: "\(UUID(-20).uuidString)/assistant", role: .assistant, text: "Turn failed.", isError: true),
            ]
        )
    }

    @Test
    func isIntakeUntilThereAreMessages() async throws {
        let database = try Self.makeDatabase()
        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            DesignModel(worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1), database: database)
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
            DesignModel(worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1), database: database)
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
            DesignModel(worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1), database: database)
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
            DesignModel(worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1), database: database)
        }

        model.draftText = "hi"
        model.submit()
        await model.runTask?.value

        #expect(model.errorText != nil)
        #expect(!model.isRunning)
    }

    // MARK: - Helpers

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignTests-\(UUID().uuidString)", isDirectory: true)
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
