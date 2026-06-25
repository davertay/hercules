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
                    kind: request.kind,
                    skillFiles: request.skillFiles,
                    addDirs: request.addDirs
                )
            }
        } operation: {
            ChatEngine(
                worktree: URL(fileURLWithPath: "/repo"), mode: .readOnly, workflowID: UUID(-1),
                kind: .design, skillFiles: skillFiles, addDirs: addDirs, database: database
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
        #expect(request.kind == .design)
        #expect(request.skillFiles == skillFiles)
        #expect(request.addDirs == addDirs)
        #expect(engine.draftText.isEmpty)
        #expect(!engine.isRunning)
        #expect(engine.errorText == nil)
    }

    @Test
    func firstSubmitThreadsMCPServersIntoStartRequest() async throws {
        let database = try Self.makeDatabase()
        let mcpServers = [
            MCPServer(
                name: "hercules", command: "/repo/.build/hercules",
                args: ["--mcp-issue-server", "--db", "/wf.sqlite"], tools: ["create_issue"]
            )
        ]
        let captured = LockIsolated<StartRequest?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return Session(
                    id: Session.ID(rawValue: UUID(100)),
                    worktree: request.worktree,
                    mode: request.mode,
                    kind: request.kind
                )
            }
        } operation: {
            ChatEngine(
                worktree: URL(fileURLWithPath: "/repo"), mode: .readOnly, workflowID: UUID(-1),
                kind: .design, mcpServers: mcpServers, database: database
            )
        }

        engine.draftText = "Propose issues"
        engine.submit()
        await engine.runTask?.value

        #expect(captured.value?.mcpServers == mcpServers)
    }

    @Test
    func mcpServersDefaultEmptySoOtherSurfacesAreUnaffected() async throws {
        let database = try Self.makeDatabase()
        let captured = LockIsolated<StartRequest?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return Session(
                    id: Session.ID(rawValue: UUID(100)),
                    worktree: request.worktree, mode: request.mode, kind: request.kind
                )
            }
        } operation: {
            Self.makeEngine(database: database)
        }

        engine.draftText = "What are we building?"
        engine.submit()
        await engine.runTask?.value

        #expect(captured.value?.mcpServers.isEmpty == true)
    }

    @Test
    func rediscoveredSessionPinsMCPServersForResume() async throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(-2)
        try Self.seedSession(database, sessionID: sessionID, kind: .design)
        let mcpServers = [MCPServer(name: "hercules", command: "/repo/.build/hercules", tools: ["create_issue"])]

        let engine = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ChatEngine(
                worktree: URL(fileURLWithPath: "/repo"), mode: .readOnly, workflowID: UUID(-1),
                kind: .design, mcpServers: mcpServers, database: database
            )
        }

        // The reconstituted Session carries the servers so a resume Turn re-passes them (ADR 0001).
        #expect(engine.session?.mcpServers == mcpServers)
    }

    @Test
    func sendWithPerTurnOverrideFlowsIntoSendRequest() async throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(-2)
        try Self.seedSession(database, sessionID: sessionID, kind: .design)
        let override = [
            MCPServer(name: "hercules", command: "/repo/.build/hercules", tools: ["create_issue"])
        ]
        let captured = LockIsolated<SendRequest?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.send = { @Sendable request in
                captured.setValue(request)
                return request.session
            }
        } operation: {
            Self.makeEngine(database: database, kind: .design)
        }

        // The rediscovered Session lets this resume; the override rides the single Turn (ADR 0001).
        try await engine.send("propose issues", overrideMCPServers: override)

        #expect(captured.value?.mcpServers == override)
    }

    @Test
    func sendWithoutOverrideLeavesSendRequestServersAbsentForFallback() async throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(-2)
        try Self.seedSession(database, sessionID: sessionID, kind: .design)
        let captured = LockIsolated<SendRequest?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.send = { @Sendable request in
                captured.setValue(request)
                return request.session
            }
        } operation: {
            Self.makeEngine(database: database, kind: .design)
        }

        try await engine.send("follow up")

        // Absent override → nil, the signal for HarnessRunner to fall back to session.mcpServers.
        #expect(captured.value?.mcpServers == nil)
    }

    @Test
    func followUpSubmitResumesSameSession() async throws {
        let database = try Self.makeDatabase()
        let startedSession = Session(
            id: Session.ID(rawValue: UUID(100)),
            worktree: URL(fileURLWithPath: "/repo"),
            mode: .readOnly,
            kind: .design
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

    @Test
    func cancelStopsInFlightTurnClearsRunningAndLeavesEngineReadyForAFreshTurn() async throws {
        let database = try Self.makeDatabase()
        let startCount = LockIsolated(0)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                startCount.withValue { $0 += 1 }
                if startCount.value == 1 {
                    // The first Turn hangs on a cancellable sleep so the engine stays running until stopped.
                    try await Task.sleep(for: .seconds(60))
                    throw CancellationError()
                }
                // A fresh Turn after cancellation starts a new Session and completes.
                return Session(
                    id: Session.ID(rawValue: UUID(100)),
                    worktree: request.worktree, mode: request.mode, kind: request.kind
                )
            }
        } operation: {
            Self.makeEngine(database: database)
        }

        engine.draftText = "first"
        engine.submit()
        #expect(engine.isRunning)

        // Cancellation clears the flag immediately, before the cancelled Turn finishes unwinding.
        engine.cancel()
        #expect(!engine.isRunning)
        await engine.runTask?.value

        // The engine accepts and runs a fresh Turn afterwards.
        engine.draftText = "second"
        engine.submit()
        await engine.runTask?.value

        #expect(!engine.isRunning)
        #expect(engine.errorText == nil)
        #expect(startCount.value == 2)
        #expect(engine.session?.id.rawValue == UUID(100))
    }

    // MARK: - Scoping and rediscovery (ADR 0005)

    @Test
    func conversationIsScopedToTheEngineKind() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(-1)
        let designSession = UUID(-2)
        let prdSession = UUID(-3)
        try Self.seedSession(database, sessionID: designSession, workflowID: workflowID, kind: .design)
        try Self.seedSession(
            database, sessionID: prdSession, workflowID: workflowID, kind: .prd, seedWorkflow: false
        )
        try await database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-10), sessionID: designSession, userPrompt: "design prompt",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-20), sessionID: prdSession, userPrompt: "prd prompt",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }

        let designEngine = Self.makeEngine(database: database, kind: .design)
        try await designEngine.$conversation.load()
        let prdEngine = Self.makeEngine(database: database, kind: .prd)
        try await prdEngine.$conversation.load()

        // Each surface sees only its own Session's Turns — no cross-Session bleed.
        #expect(designEngine.messages.map(\.text) == ["design prompt"])
        #expect(prdEngine.messages.map(\.text) == ["prd prompt"])
    }

    @Test
    func rediscoversExistingSessionOnConstructionAndShowsHistory() async throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(-2)
        try Self.seedSession(database, sessionID: sessionID, kind: .design)
        try await database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-10), sessionID: sessionID, userPrompt: "earlier turn",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }

        let engine = Self.makeEngine(database: database, kind: .design)
        try await engine.$conversation.load()

        // The Session is reconstituted from the row (id, pinned worktree, mode, kind) so a follow-up
        // resumes it, and reopening shows the prior history.
        #expect(engine.session?.id.rawValue == sessionID)
        #expect(engine.session?.kind == .design)
        #expect(engine.session?.worktree == URL(fileURLWithPath: "/repo"))
        #expect(engine.session?.mode == .readOnly)
        #expect(!engine.isIntake)
        #expect(engine.messages.map(\.text) == ["earlier turn"])
    }

    @Test
    func followUpAfterRediscoveryResumesRatherThanStarts() async throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(-2)
        try Self.seedSession(database, sessionID: sessionID, kind: .design)
        let resumed = LockIsolated<SendRequest?>(nil)
        let didStart = LockIsolated(false)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable _ in
                didStart.setValue(true)
                return Session(id: Session.ID(rawValue: UUID(99)), worktree: URL(fileURLWithPath: "/repo"), mode: .readOnly, kind: .design)
            }
            $0.agentClient.send = { @Sendable request in
                resumed.setValue(request)
                return request.session
            }
        } operation: {
            Self.makeEngine(database: database, kind: .design)
        }

        engine.draftText = "follow up"
        engine.submit()
        await engine.runTask?.value

        #expect(!didStart.value)
        #expect(resumed.value?.session.id.rawValue == sessionID)
    }

    @Test
    func noRediscoveryWhenNoSessionOfThatKindExists() async throws {
        let database = try Self.makeDatabase()
        // A Session of a *different* kind exists in the same Workflow; it must not be rediscovered.
        try Self.seedSession(database, sessionID: UUID(-2), kind: .prd)

        let engine = Self.makeEngine(database: database, kind: .design)
        try await engine.$conversation.load()

        #expect(engine.session == nil)
        #expect(engine.isIntake)
    }

    // MARK: - Helpers

    private static func makeEngine(
        database: any DatabaseWriter,
        kind: SessionKind = .design
    ) -> ChatEngine {
        withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ChatEngine(
                worktree: URL(fileURLWithPath: "/repo"), mode: .readOnly, workflowID: UUID(-1),
                kind: kind, database: database
            )
        }
    }

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }

    private static func seedSession(
        _ database: any DatabaseWriter,
        sessionID: UUID,
        workflowID: UUID = UUID(-1),
        kind: SessionKind = .design,
        seedWorkflow: Bool = true
    ) throws {
        try database.write { db in
            if seedWorkflow {
                try WorkflowRow.insert {
                    WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
                }
                .execute(db)
            }
            try SessionRow.insert {
                SessionRow(
                    id: sessionID, workflowID: workflowID, worktreePath: "/repo", mode: "readOnly",
                    kind: kind.rawValue, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }
}
