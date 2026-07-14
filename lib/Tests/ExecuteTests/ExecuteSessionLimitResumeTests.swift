import Agent
import Clocks
import Dependencies
import Foundation
import IssueGraph
import Skills
import SQLiteData
import Store
import Testing
import Worktree

@testable import Execute

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

/// A real, parseable session-limit final answer (the Harness's stable wording) whose reset time
/// `SessionLimitReset` can turn into a `Date` — the trigger for auto-resume.
private let limitMessage = "You've hit your session limit · resets 11pm (UTC)"

/// Exercises the auto-resume-after-session-limit behaviour (#160) on `ExecuteModel.run`: a fault whose
/// errored turn is a parseable session-limit message pauses the run on a cancellable clock, then re-runs
/// the Issue and carries on; every other fault halts as before.
@MainActor
@Suite("ExecuteModel session-limit auto-resume")
struct ExecuteSessionLimitResumeTests {

    @Test("A session-limit fault pauses the run, then resumes and finishes once the reset elapses")
    func pausesOnSessionLimitThenResumesToDone() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let clock = TestClock()
        let prompts = LockIsolated<[String]>([])
        let issue1Attempts = LockIsolated(0)
        let sessionSeq = LockIsolated(200)
        let head = LockIsolated(0)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.agentClient.start = { @Sendable request in
                prompts.withValue { $0.append(request.prompt) }
                let id = UUID(sessionSeq.withValue { $0 += 1; return $0 })
                // Issue #1's first attempt hits the session limit: record the errored turn the way the
                // Harness does, then throw as the live client does on a non-zero exit.
                if request.issueNumber == 1, issue1Attempts.withValue({ $0 += 1; return $0 }) == 1 {
                    try await Self.recordSession(for: request, id: id, finalAnswer: limitMessage, isError: true)
                    throw AgentError.harnessFailed(exitCode: 1, stderrTail: limitMessage)
                }
                return try await Self.recordSession(for: request, id: id)
            }
            $0.agentClient.send = { @Sendable _ in
                Issue.record("Auto-resume must start a fresh Session, never resume one")
                throw CancellationError()
            }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        model.start()

        // The run parks in the wait: `resumingAt` is published, the run is still `isRunning`, and the Issue
        // sits `failed` in the store (not `.inProgress`, so its elapsed can't clock the wait).
        await Self.waitUntil { model.resumingAt != nil }
        let expectedResumeAt = try #require(SessionLimitReset.parse(limitMessage, now: fixedDate))
            .addingTimeInterval(60)
        #expect(model.resumingAt == expectedResumeAt)
        #expect(model.isRunning == true)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
        // Presented as the pending/next-up node, never in-progress, while it waits.
        #expect(model.nodes.first { $0.number == 1 }?.status == .ready)

        // Advance past the reset instant: the wait ends, the Issue re-runs fresh and the loop continues
        // downstream to #2.
        await clock.advance(by: .seconds(expectedResumeAt.timeIntervalSince(fixedDate) + 1))
        await model.runTask.value?.value

        #expect(model.resumingAt == nil)
        #expect(model.isRunning == false)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "done")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "done")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == true)

        // First run of each Issue sends the body unchanged; the resumed re-run of #1 appends the
        // interruption note so the fresh session picks up the worktree's partial work.
        #expect(prompts.value.count == 3)
        #expect(prompts.value[0] == "Implement 1.")
        #expect(prompts.value[1].hasPrefix("Implement 1.\n\n"))
        #expect(prompts.value[1].contains("interrupted before it finished"))
        #expect(prompts.value[2] == "Implement 2.")
    }

    @Test("Stop during the wait cancels it, leaving the Issue a normal failed with its Retry")
    func stopDuringWaitLeavesIssueFailed() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let clock = TestClock()
        let head = LockIsolated(0)
        let sessionSeq = LockIsolated(200)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.agentClient.start = { @Sendable request in
                let id = UUID(sessionSeq.withValue { $0 += 1; return $0 })
                try await Self.recordSession(for: request, id: id, finalAnswer: limitMessage, isError: true)
                throw AgentError.harnessFailed(exitCode: 1, stderrTail: limitMessage)
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        model.start()
        await Self.waitUntil { model.resumingAt != nil }

        // Stop cancels the run task, which throws out of the sleep — the escape hatch.
        model.stop()
        await model.runTask.value?.value

        #expect(model.isRunning == false)
        #expect(model.resumingAt == nil)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "new")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == false)
    }

    @Test("A non-limit error halts the run without arming a wait")
    func nonLimitErrorHaltsWithoutArmingWait() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let clock = TestClock()
        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.agentClient.start = { @Sendable request in
                // A genuine crash: an errored turn whose text is not a session-limit message.
                try await Self.recordSession(
                    for: request, id: UUID(201), finalAnswer: "The harness crashed unexpectedly.", isError: true
                )
                throw AgentError.harnessCrashed(signal: 9, stderrTail: "boom")
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in "same-sha" }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        await model.run()

        #expect(model.resumingAt == nil)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "new")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == false)
    }

    @Test("A session-limit message whose time won't parse halts (fail safe to manual), no wait")
    func unparseableSessionLimitHaltsWithoutArmingWait() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.agentClient.start = { @Sendable request in
                // Mentions the limit but the reset zone is unknown, so `SessionLimitReset` returns nil.
                try await Self.recordSession(
                    for: request, id: UUID(201),
                    finalAnswer: "You've hit your session limit · resets 11pm (Mars/Olympus)", isError: true
                )
                throw AgentError.harnessFailed(exitCode: 1, stderrTail: "limit")
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in "same-sha" }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        await model.run()

        #expect(model.resumingAt == nil)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
    }

    @Test("An exit-0 no-op (a clean turn, no errored turn) halts without arming a wait")
    func exitZeroNoOpHaltsWithoutArmingWait() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.agentClient.start = { @Sendable request in
                // A blocked agent: it finished cleanly (no errored turn) but committed nothing.
                try await Self.recordSession(
                    for: request, id: UUID(201), finalAnswer: "I'm blocked — need your input.", isError: false
                )
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in "same-sha" }
            $0.worktreeClient.isDirty = { @Sendable _ in false }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        await model.run()

        #expect(model.resumingAt == nil)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
    }

    @Test("A manual re-run (a prior Session exists) appends the interruption note; a first run doesn't")
    func rerunAppendsInterruptionNote() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        // A prior execute Session for #1, standing in for an earlier (interrupted) attempt.
        try Self.seedExecuteSession(database, workflowID: workflowID, issueNumber: 1, id: UUID(50))

        let captured = LockIsolated<String?>(nil)
        let head = LockIsolated(0)
        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request.prompt)
                return try await Self.recordSession(for: request, id: UUID(201))
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        let prompt = try #require(captured.value)
        #expect(prompt.hasPrefix("Implement 1.\n\n"))
        #expect(prompt.contains("Inspect the working tree first"))
    }

    // MARK: - Helpers

    /// Polls `condition`, yielding between checks so the MainActor run task can make progress.
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    /// Records the `execute` Session as the Agent would, plus (when a `finalAnswer` is given) one Turn —
    /// `isError` set to stand in for the session-limit/crash errored turn the Harness streams.
    @discardableResult
    private static func recordSession(
        for request: StartRequest, id: UUID, finalAnswer: String? = nil, isError: Bool = false
    ) async throws -> Session {
        try await request.database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: id, workflowID: request.workflowID, worktreePath: request.worktree.path,
                    mode: request.mode.rawValue, kind: request.kind.rawValue,
                    issueNumber: request.issueNumber, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            if let finalAnswer {
                try TurnRow.insert {
                    TurnRow(
                        id: UUID(), sessionID: id, userPrompt: request.prompt,
                        finalAnswer: finalAnswer, isError: isError, createdAt: fixedDate, updatedAt: fixedDate
                    )
                }
                .execute(db)
            }
        }
        return Session(
            id: Session.ID(rawValue: id), worktree: request.worktree, mode: request.mode,
            kind: request.kind, skillFiles: request.skillFiles, addDirs: request.addDirs,
            mcpServers: request.mcpServers
        )
    }

    private static func seedExecuteSession(
        _ database: any DatabaseWriter, workflowID: UUID, issueNumber: Int, id: UUID
    ) throws {
        try database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: id, workflowID: workflowID, worktreePath: "/repo",
                    mode: AgentMode.write.rawValue, kind: SessionKind.execute.rawValue,
                    issueNumber: issueNumber, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func seedIssue(
        _ database: any DatabaseWriter, workflowID: UUID, number: Int, dependencies: [Int]
    ) throws {
        try database.write { db in
            try WorkflowRow
                .upsert {
                    WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
                }
                .execute(db)
            try IssueRow.insert {
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: number, title: "Issue \(number)",
                    body: "Implement \(number).", dependencies: dependencies, status: "new",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func issue(
        _ database: any DatabaseWriter, workflowID: UUID, number: Int
    ) throws -> IssueRow? {
        try database.read { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) && $0.number.eq(number) }
                .fetchOne(db)
        }
    }

    private static func status(
        _ database: any DatabaseWriter, workflowID: UUID, number: Int
    ) throws -> String? {
        try issue(database, workflowID: workflowID, number: number)?.status
    }

    private static func executeCompleted(
        _ database: any DatabaseWriter, workflowID: UUID
    ) throws -> Bool {
        try database.read { db in
            try PhaseRow
                .where { $0.workflowID.eq(workflowID) && $0.kind.eq("execute") }
                .where { $0.status.eq("complete") }
                .where { !$0.isDeleted }
                .fetchOne(db)
        } != nil
    }

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecuteSessionLimitResumeTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }
}
