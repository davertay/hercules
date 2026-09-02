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
/// `SessionLimitReset` can turn into a `Date` — the timing half of auto-resume.
private let limitMessage = "You've hit your session limit · resets 11pm (UTC)"

/// Exercises the auto-resume-after-rate-limit behaviour on `ExecuteModel.run`: a failure the Harness
/// itself reported as `rate_limit`, whose message also yields a reset time, pauses the run on a
/// cancellable clock, then re-runs the Issue and carries on. Every other failure halts the run — the
/// classification is the reported reason, never the wording of the message.
@MainActor
@Suite("ExecuteModel session-limit auto-resume")
struct ExecuteSessionLimitResumeTests {

    @Test("A reported rate limit pauses the run, then resumes and finishes once the reset elapses")
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
                // Issue #1's first attempt hits the rate limit: record the errored turn the way the
                // Harness does, then throw as the live client does on a non-zero exit whose Harness
                // reported why it stopped.
                if request.issueNumber == 1, issue1Attempts.withValue({ $0 += 1; return $0 }) == 1 {
                    try await Self.recordSession(for: request, id: id, finalAnswer: limitMessage, isError: true)
                    throw AgentError.harnessFailed(exitCode: 1, stderrTail: limitMessage, reason: "rate_limit")
                }
                return try await Self.recordSession(for: request, id: id)
            }
            $0.agentClient.send = { @Sendable _ in
                Issue.record("Auto-resume must start a fresh Session, never resume one")
                throw CancellationError()
            }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(context: WorkflowContext(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory, mcpServerCommand: "hercules"
            ))
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

    @Test("The paused Issue is named even when a lower-numbered failed Issue would win haltingFailure")
    func pausedIssueWinsOverLowerNumberedFailure() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        // A pre-existing failure from an earlier, unrelated run. It's the lowest-numbered `failed` Issue, so
        // `haltingFailure` names it — but it isn't `new`, so the run skips it and never re-runs it.
        try Self.seedIssue(
            database, workflowID: workflowID, number: 2, dependencies: [],
            status: "failed", failureReason: "An earlier, unrelated failure."
        )
        // An independent, ready Issue the run does pick up — and pauses on a session limit.
        try Self.seedIssue(database, workflowID: workflowID, number: 5, dependencies: [])

        let clock = TestClock()
        let head = LockIsolated(0)
        let sessionSeq = LockIsolated(200)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.agentClient.start = { @Sendable request in
                // The only ready Issue (#5) hits the rate limit: record the errored turn, then throw.
                let id = UUID(sessionSeq.withValue { $0 += 1; return $0 })
                try await Self.recordSession(for: request, id: id, finalAnswer: limitMessage, isError: true)
                throw AgentError.harnessFailed(exitCode: 1, stderrTail: limitMessage, reason: "rate_limit")
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(context: WorkflowContext(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory, mcpServerCommand: "hercules"
            ))
        }

        model.start()
        // Park in the wait, with the observed Issue rows reflecting #5's demotion to `failed`.
        await Self.waitUntil { model.resumingIssue?.number == 5 }

        // The accessor (and so the resume banner) names the Issue actually being resumed…
        #expect(model.resumingIssue?.number == 5)
        // …even though `haltingFailure` — the lowest-numbered `failed` Issue — names the pre-existing #2.
        // The two diverge; the banner must follow `resumingIssue`, not `haltingFailure`.
        #expect(model.haltingFailure?.number == 2)
        // The node recolouring reads the same source, so it can't disagree with the banner: #5 shows as the
        // pending/next-up node while #2 stays a plain failed one.
        #expect(model.nodes.first { $0.number == 5 }?.status == .ready)
        #expect(model.nodes.first { $0.number == 2 }?.status == .failed)

        // Stop cleans up the parked run task.
        model.stop()
        await model.runTask.value?.value
        #expect(model.resumingIssue == nil)
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
                throw AgentError.harnessFailed(exitCode: 1, stderrTail: limitMessage, reason: "rate_limit")
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(context: WorkflowContext(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory, mcpServerCommand: "hercules"
            ))
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
            ExecuteModel(context: WorkflowContext(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory, mcpServerCommand: "hercules"
            ))
        }

        await model.run()

        #expect(model.resumingAt == nil)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "new")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == false)
    }

    @Test("A reported rate limit whose reset time won't parse reports that, and halts for manual Retry")
    func rateLimitWithUnreadableResetHaltsAndSaysSo() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])

        let unreadable = "You've hit your session limit · resets 11pm (Mars/Olympus)"
        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.agentClient.start = { @Sendable request in
                // A genuine rate limit, but the reset zone is unknown so `SessionLimitReset` yields no
                // `Date` — there is nothing to sleep until.
                try await Self.recordSession(for: request, id: UUID(201), finalAnswer: unreadable, isError: true)
                throw AgentError.harnessFailed(exitCode: 1, stderrTail: "limit", reason: "rate_limit")
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in "same-sha" }
        } operation: {
            ExecuteModel(context: WorkflowContext(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory, mcpServerCommand: "hercules"
            ))
        }

        await model.run()

        // No wait armed, and the Issue is left `failed` for a manual Retry — no invented backoff.
        #expect(model.resumingAt == nil)
        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        #expect(issue.status == "failed")

        // The halt names what actually happened, both on the Issue and in what the banner and inspector
        // read — which otherwise prefer the Harness's own words, here the very words we couldn't read.
        let recorded = try #require(issue.failureReason)
        #expect(recorded.contains("rate limit"))
        #expect(recorded.contains("couldn't read a reset time"))
        #expect(model.failureReason(for: issue) == recorded)
        #expect(model.failureReason(for: issue) != unreadable)
    }

    @Test("A reported non-rate-limit halts even when its message reads exactly like a session limit")
    func reportedNonRateLimitHaltsDespiteLimitWording() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.agentClient.start = { @Sendable request in
                // The message parses perfectly as a session limit; the Harness says it stopped for
                // another reason entirely. The reported reason decides, so this must not park the run.
                try await Self.recordSession(for: request, id: UUID(201), finalAnswer: limitMessage, isError: true)
                throw AgentError.harnessFailed(exitCode: 1, stderrTail: limitMessage, reason: "overloaded")
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in "same-sha" }
        } operation: {
            ExecuteModel(context: WorkflowContext(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory, mcpServerCommand: "hercules"
            ))
        }

        await model.run()

        // Halted, not waiting — and with no retry policy of its own: `overloaded` gets the same treatment
        // every other non-rate-limit failure gets.
        #expect(model.resumingAt == nil)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "new")
        // The recorded reason is the untouched one from the throw, not the rate-limit account.
        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        #expect(issue.failureReason == AgentError
            .harnessFailed(exitCode: 1, stderrTail: limitMessage, reason: "overloaded").localizedDescription)
    }

    @Test("No reported reason (no drop-file) takes the ordinary failure path, whatever the message says")
    func noReportedReasonHaltsWithoutArmingWait() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.agentClient.start = { @Sendable request in
                // The hook didn't fire — no drop-file, so no reason. A failure that reported nothing about
                // itself is an ordinary failure, and the run halts on it exactly as on any other.
                try await Self.recordSession(for: request, id: UUID(201), finalAnswer: limitMessage, isError: true)
                throw AgentError.harnessFailed(exitCode: 1, stderrTail: limitMessage, reason: nil)
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
            $0.worktreeClient.headSHA = { @Sendable _ in "same-sha" }
        } operation: {
            ExecuteModel(context: WorkflowContext(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory, mcpServerCommand: "hercules"
            ))
        }

        await model.run()

        #expect(model.resumingAt == nil)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "new")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == false)
        // Recorded byte for byte as this failure has always been recorded: nothing about the missing
        // drop-file changes the reason, and nothing rewrote it on the way out.
        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        #expect(issue.failureReason == AgentError
            .harnessFailed(exitCode: 1, stderrTail: limitMessage, reason: nil).localizedDescription)
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
            ExecuteModel(context: WorkflowContext(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory, mcpServerCommand: "hercules"
            ))
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
            ExecuteModel(context: WorkflowContext(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory, mcpServerCommand: "hercules"
            ))
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
        _ database: any DatabaseWriter, workflowID: UUID, number: Int, dependencies: [Int],
        status: String = "new", failureReason: String? = nil
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
                    body: "Implement \(number).", dependencies: dependencies, status: status,
                    failureReason: failureReason, createdAt: fixedDate, updatedAt: fixedDate
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
