import Agent
import Dependencies
import Foundation
import SQLiteData
import Store
import Testing

@testable import Chat

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

/// One row of the card's table: what the user picked, what they typed, and the payload it sends — or
/// `nil` where there is no answer to send.
struct AnswerRow: Sendable {
    var pick: String?
    var note: String
    var sends: QuestionAnswer?
}

/// The live question card, driven the way the whole feature is driven in the app: a Turn asks through
/// the substituted agent client, the card comes up, and the answer goes back to the call that is still
/// waiting on it. No subprocess, no files, no MCP — the callback on the request *is* the seam.
@MainActor
@Suite("Chat — the live question card")
struct ChatQuestionTests {
    private let storage = Question(
        header: "Storage",
        question: "How should offline notes be stored?",
        options: [
            Question.Option(label: "Use SQLite", description: "A real database, migrations and all"),
            Question.Option(label: "Use a flat file", description: "One JSON blob, rewritten on save"),
        ]
    )
    private let sync = Question(
        header: "Sync",
        question: "What should happen to edits made while offline?",
        multiSelect: true,
        options: [
            Question.Option(label: "Last write wins", description: "Simplest, loses concurrent edits"),
            Question.Option(label: "Keep both", description: "Fork the note and let the user merge"),
        ]
    )

    // MARK: - The round trip

    /// The whole of it on a first Turn: the question reaches the Chat and the card comes up, the Turn
    /// goes on running with the composer locked behind it, and Submit resumes the blocked call with the
    /// label exactly as the agent worded it and the note as a field of its own.
    @Test
    func theCardComesUpWhileTheCallWaitsAndGoesWhenItIsAnswered() async throws {
        let database = try Self.makeDatabase()
        let question = storage
        let delivered = LockIsolated<Answer?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                let onQuestion = try #require(request.onQuestion)
                let answer = await onQuestion([question])
                delivered.setValue(answer)
                return Session(
                    id: Session.ID(rawValue: UUID(100)),
                    worktree: request.worktree, mode: request.mode, kind: request.kind
                )
            }
        } operation: {
            Self.makeEngine(database: database)
        }

        engine.draftText = "How should this store notes?"
        engine.submit()

        let card = try await Self.card(of: engine)
        #expect(card.questions == [question])
        // A pending question must never read as a stalled agent: the Turn is still running, so the
        // running indicator stays up and the composer stays locked — typing changes neither.
        #expect(engine.isRunning)
        engine.draftText = "answered in the composer instead"
        #expect(engine.isSendDisabled)

        card.toggle("Use SQLite", at: 0)
        card.drafts[0].note = "but keep migrations in a separate file"
        card.submit()
        await engine.runTask?.value

        #expect(engine.pendingQuestion == nil)
        #expect(
            delivered.value
                == .answered([
                    QuestionAnswer(
                        header: "Storage",
                        selected: ["Use SQLite"],
                        note: "but keep migrations in a separate file"
                    )
                ])
        )
    }

    /// The same on a resume Turn, which is what every question after the first one of a conversation is.
    @Test
    func aQuestionOnAResumeTurnRendersTheCardToo() async throws {
        let database = try Self.makeDatabase()
        let question = storage
        let delivered = LockIsolated<Answer?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.send = { @Sendable request in
                let onQuestion = try #require(request.onQuestion)
                let answer = await onQuestion([question])
                delivered.setValue(answer)
                return request.session
            }
        } operation: {
            Self.makeEngine(database: database)
        }
        try Self.seedSession(database, sessionID: UUID(-2))
        try await engine.$existingSessionRow.load()

        engine.draftText = "carry on"
        engine.submit()

        let card = try await Self.card(of: engine)
        card.toggle("Use a flat file", at: 0)
        card.submit()
        await engine.runTask?.value

        #expect(delivered.value == .answered([QuestionAnswer(header: "Storage", selected: ["Use a flat file"])]))
    }

    /// An interview: the Turn asks, takes the answer, and asks the next question — no Turn boundary
    /// between the exchanges, which is the whole reason for asking through a tool rather than by ending
    /// the turn with a question. Each question gets its own card and its own answer.
    @Test
    func aTurnAsksItsNextQuestionWithoutEndingTheTurn() async throws {
        let database = try Self.makeDatabase()
        let (first, second) = (storage, sync)
        let answers = LockIsolated<[Answer]>([])

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                let onQuestion = try #require(request.onQuestion)
                for question in [first, second] {
                    let answer = await onQuestion([question])
                    answers.withValue { $0.append(answer) }
                }
                return Session(
                    id: Session.ID(rawValue: UUID(100)),
                    worktree: request.worktree, mode: request.mode, kind: request.kind
                )
            }
        } operation: {
            Self.makeEngine(database: database)
        }

        engine.draftText = "interview me"
        engine.submit()

        let opening = try await Self.card(of: engine)
        #expect(opening.questions == [first])
        opening.toggle("Use SQLite", at: 0)
        opening.submit()

        // The Turn never ended, so the follow-up arrives on the same one — a second card, not a second
        // conversation.
        let followUp = try await Self.card(of: engine)
        #expect(followUp.questions == [second])
        #expect(engine.isRunning)
        followUp.toggle("Keep both", at: 0)
        followUp.submit()
        await engine.runTask?.value

        #expect(
            answers.value == [
                .answered([QuestionAnswer(header: "Storage", selected: ["Use SQLite"])]),
                .answered([QuestionAnswer(header: "Sync", selected: ["Keep both"])]),
            ]
        )
    }

    /// The Design summary and the Allocate commit run as a Turn whose writer rides a per-Turn override.
    /// The override replaces the Session's pinned servers, but attendedness is not one of them — so the
    /// Turn still carries the question tool, and a last "did I capture this right?" reaches the user.
    @Test
    func aFinalizationTurnCanStillAskItsLastQuestion() async throws {
        let database = try Self.makeDatabase()
        let question = storage
        let writer = MCPServer.artifactWriter(
            command: "/path/to/Hercules",
            artifactURL: URL(fileURLWithPath: "/tmp/wf/phases/design/summary.md")
        )
        let resumed = LockIsolated<SendRequest?>(nil)
        let delivered = LockIsolated<Answer?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.send = { @Sendable request in
                resumed.setValue(request)
                let onQuestion = try #require(request.onQuestion)
                let answer = await onQuestion([question])
                delivered.setValue(answer)
                return request.session
            }
        } operation: {
            Self.makeEngine(database: database)
        }
        try Self.seedSession(database, sessionID: UUID(-2))
        try await engine.$existingSessionRow.load()

        let task = engine.run { try await engine.send("write the summary", overrideMCPServers: [writer]) }
        let card = try await Self.card(of: engine)
        card.drafts[0].note = "call it 'offline notes'"
        card.submit()
        await task.value

        #expect(resumed.value?.mcpServers == [writer])
        #expect(delivered.value == .answered([QuestionAnswer(header: "Storage", selected: [], note: "call it 'offline notes'")]))
    }

    /// The other side of the predicate. A Chat over an unattended kind offers no answer, so the Turn is
    /// given neither the tool nor the rules and its agent has nothing to block on — which is what keeps a
    /// behind-the-scenes run failing visibly instead of waiting for a user who isn't there.
    @Test
    func aTurnOfAnUnattendedKindIsOfferedNoAnswerAtAll() async throws {
        let database = try Self.makeDatabase()
        let started = LockIsolated<StartRequest?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                started.setValue(request)
                return Session(
                    id: Session.ID(rawValue: UUID(100)),
                    worktree: request.worktree, mode: request.mode, kind: request.kind
                )
            }
        } operation: {
            Self.makeEngine(database: database, kind: .execute)
        }

        engine.draftText = "do the work"
        engine.submit()
        await engine.runTask?.value

        #expect(started.value?.onQuestion == nil)
        #expect(engine.pendingQuestion == nil)
    }

    // MARK: - What the card sends

    /// Every row of the table, on the model the card binds to. The note field is always there and its
    /// meaning follows from the selection, so "that option, but with this tweak" and "none of these, but
    /// this instead" are the same control used two ways rather than an option and an escape hatch.
    @Test(arguments: [
        AnswerRow(
            pick: "Use SQLite", note: "",
            sends: QuestionAnswer(header: "Storage", selected: ["Use SQLite"])
        ),
        AnswerRow(
            pick: "Use SQLite", note: "but keep migrations in a separate file",
            sends: QuestionAnswer(
                header: "Storage", selected: ["Use SQLite"], note: "but keep migrations in a separate file"
            )
        ),
        AnswerRow(
            pick: nil, note: "Neither — put them in the user's iCloud container",
            sends: QuestionAnswer(
                header: "Storage", selected: [], note: "Neither — put them in the user's iCloud container"
            )
        ),
        AnswerRow(pick: nil, note: "", sends: nil),
        AnswerRow(pick: nil, note: "   \n ", sends: nil),
    ])
    func eachRowOfTheTableSendsItsOwnPayload(_ row: AnswerRow) async throws {
        let delivered = LockIsolated<Answer?>(nil)
        let card = PendingQuestion(questions: [storage]) { delivered.setValue($0) }

        if let pick = row.pick { card.toggle(pick, at: 0) }
        card.drafts[0].note = row.note

        #expect(card.canSubmit == (row.sends != nil))
        card.submit()

        if let sends = row.sends {
            #expect(delivered.value == .answered([sends]))
        } else {
            // Nothing picked and nothing typed is the row with no answer in it: Submit is refused and the
            // call is left waiting rather than told something the user never said.
            #expect(delivered.value == nil)
        }
    }

    /// The multi-select flag decides whether picks accumulate, and a pick can always be undone — which is
    /// what lets an answer that started as "that one" become the note alone.
    @Test
    func multiSelectAccumulatesPicksWhereASingleSelectReplacesThem() async throws {
        let card = PendingQuestion(questions: [storage, sync]) { _ in }

        card.toggle("Use SQLite", at: 0)
        card.toggle("Use a flat file", at: 0)
        #expect(card.drafts[0].selected == ["Use a flat file"])

        // Picked back to front, but they come back in the order the agent listed them.
        card.toggle("Keep both", at: 1)
        card.toggle("Last write wins", at: 1)
        #expect(card.drafts[1].selected == ["Last write wins", "Keep both"])

        card.toggle("Last write wins", at: 1)
        #expect(card.drafts[1].selected == ["Keep both"])
        card.toggle("Use a flat file", at: 0)
        #expect(card.drafts[0].selected.isEmpty)
    }

    /// One call may carry several questions and one answer covers the whole call, so every question in it
    /// has to be answered before any of it is sent.
    @Test
    func severalQuestionsInOneCallAreAnsweredTogether() async throws {
        let delivered = LockIsolated<Answer?>(nil)
        let card = PendingQuestion(questions: [storage, sync]) { delivered.setValue($0) }

        card.toggle("Use SQLite", at: 0)
        #expect(!card.canSubmit)

        card.drafts[1].note = "Fork it and let me merge"
        #expect(card.canSubmit)
        card.submit()

        #expect(
            delivered.value
                == .answered([
                    QuestionAnswer(header: "Storage", selected: ["Use SQLite"]),
                    QuestionAnswer(header: "Sync", selected: [], note: "Fork it and let me merge"),
                ])
        )
    }

    // MARK: - Lifecycle

    /// The Harness abandons a call without telling anyone and the model retries, so two calls waiting at
    /// once happens. The one on screen is the one being answered; the second queues behind it rather than
    /// replacing it, which would leave a call waiting on an answer nobody would ever be shown.
    @Test
    func aSecondCallQueuesBehindTheOneOnScreen() async throws {
        let database = try Self.makeDatabase()
        let (first, second) = (storage, sync)
        let answers = LockIsolated<[String: Answer]>([:])

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                let onQuestion = try #require(request.onQuestion)
                await withTaskGroup(of: Void.self) { group in
                    for question in [first, second] {
                        group.addTask {
                            let answer = await onQuestion([question])
                            answers.withValue { $0[question.header] = answer }
                        }
                    }
                }
                return Session(
                    id: Session.ID(rawValue: UUID(100)),
                    worktree: request.worktree, mode: request.mode, kind: request.kind
                )
            }
        } operation: {
            Self.makeEngine(database: database)
        }

        engine.draftText = "two at once"
        engine.submit()

        // Both calls are waiting, but only one is on screen. Which one arrived first is the scheduler's
        // business, so each is answered with its own header to keep the assertion independent of it.
        try await Self.eventually { engine.pendingQuestions.count == 2 }
        let front = try #require(engine.pendingQuestion)
        front.drafts[0].note = front.questions[0].header
        front.submit()

        let next = try await Self.card(of: engine)
        #expect(next !== front)
        next.drafts[0].note = next.questions[0].header
        next.submit()
        await engine.runTask?.value

        #expect(engine.pendingQuestion == nil)
        #expect(
            answers.value == [
                "Storage": .answered([QuestionAnswer(header: "Storage", selected: [], note: "Storage")]),
                "Sync": .answered([QuestionAnswer(header: "Sync", selected: [], note: "Sync")]),
            ]
        )
    }

    /// Stopping the Turn takes the card with it. A card outliving its Turn would be a live control with
    /// nobody on the other end of it, and the call — if it is still there to hear it — is told what a
    /// dismissal tells it rather than something the user never said.
    @Test
    func stoppingTheTurnDismissesTheCard() async throws {
        let database = try Self.makeDatabase()
        let question = storage
        let delivered = LockIsolated<Answer?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.start = { @Sendable request in
                let onQuestion = try #require(request.onQuestion)
                let answer = await onQuestion([question])
                delivered.setValue(answer)
                // The Turn runs on after the question is answered, as a real one does.
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
        } operation: {
            Self.makeEngine(database: database)
        }

        engine.draftText = "ask me something"
        engine.submit()
        _ = try await Self.card(of: engine)

        engine.cancel()

        #expect(engine.pendingQuestion == nil)
        #expect(!engine.isRunning)
        await engine.runTask?.value
        #expect(delivered.value == .cancelled)
    }

    /// Reopening a Workflow whose question was never answered: the exchange is there as history, through
    /// the same generic tool rows every other tool produces, and there is no live control to resurrect —
    /// the card was never a Transcript row. The composer is free, so the user simply carries on typing.
    @Test
    func aReopenedWorkflowShowsAnUnansweredQuestionAsHistoryAndOffersNoCard() async throws {
        let database = try Self.makeDatabase()
        let sessionID = UUID(-2)
        try Self.seedSession(database, sessionID: sessionID)
        try await database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-10), sessionID: sessionID, userPrompt: "design the sync",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            try ContentBlockRow.insert {
                ContentBlockRow(
                    id: UUID(-11), turnID: UUID(-10), position: 0, role: "assistant", kind: "tool_use",
                    text: #"{"questions":[{"header":"Storage"}]}"#,
                    toolName: "mcp__hercules_ask__ask_user", createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            try ContentBlockRow.insert {
                ContentBlockRow(
                    id: UUID(-12), turnID: UUID(-10), position: 1, role: "user", kind: "tool_result",
                    text: "Connection closed", createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
        let resumed = LockIsolated<SendRequest?>(nil)

        let engine = withDependencies {
            $0.defaultDatabase = database
            $0.agentClient.send = { @Sendable request in
                resumed.setValue(request)
                return request.session
            }
        } operation: {
            Self.makeEngine(database: database)
        }
        try await engine.$conversation.load()

        #expect(engine.pendingQuestion == nil)
        #expect(engine.messages.map(\.kind) == [.user, .toolUse, .toolResult])
        #expect(engine.messages.map(\.toolName) == [nil, "mcp__hercules_ask__ask_user", nil])

        engine.draftText = "use SQLite"
        #expect(!engine.isSendDisabled)
        engine.submit()
        await engine.runTask?.value

        #expect(resumed.value?.prompt == "use SQLite")
    }

    // MARK: - Helpers

    /// The card once it is up. The question crosses from the Turn's own task, so a test asserting on it
    /// waits for a hop it didn't make itself.
    private static func card(
        of engine: ChatEngine,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> PendingQuestion {
        try await eventually({ engine.pendingQuestion != nil }, sourceLocation: sourceLocation)
        return try #require(engine.pendingQuestion, sourceLocation: sourceLocation)
    }

    private static func eventually(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Condition never held", sourceLocation: sourceLocation)
    }

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
            .appendingPathComponent("ChatQuestionTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }

    private static func seedSession(
        _ database: any DatabaseWriter,
        sessionID: UUID,
        workflowID: UUID = UUID(-1)
    ) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try SessionRow.insert {
                SessionRow(
                    id: sessionID, workflowID: workflowID, worktreePath: "/repo", mode: "readOnly",
                    kind: SessionKind.design.rawValue, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }
}
