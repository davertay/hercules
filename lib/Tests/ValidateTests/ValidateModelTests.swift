import Agent
import Dependencies
import Foundation
import Material
import SQLiteData
import Store
import Testing
import Worktree

@testable import Validate

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
@Suite("ValidateModel")
struct ValidateModelTests {

    @Test("review-code-quality Skill resolves from the bundle")
    func reviewSkillResolves() {
        let resource = ReviewPersona.codeQuality.skillResource
        #expect(resource.name == "review-code-quality")
        #expect(FileManager.default.fileExists(atPath: resource.fileUrl.path))
    }

    @Test("Runs a Persona as a read-only validate Session and captures its final answer as the Summary")
    func capturesSummaryAndMarksReviewed() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)
        let resource = ReviewPersona.codeQuality.skillResource
        let captured = LockIsolated<StartRequest?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return try await Self.startSession(
                    for: request, id: UUID(100), finalAnswer: "The code reads cleanly."
                )
            }
            // A review must never construct a chat engine, so resume must never be reached.
            $0.agentClient.send = { @Sendable _ in
                Issue.record("ValidateModel.review must not resume a Session")
                throw CancellationError()
            }
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }

        await Self.runScoped(model, .codeQuality)

        let request = try #require(captured.value)
        #expect(request.mode == .readOnly)
        #expect(request.worktree == FileManager.default.temporaryDirectory)
        #expect(request.workflowID == workflowID)
        #expect(request.kind == .validate)
        #expect(request.issueNumber == nil)
        #expect(request.skillFiles == [resource.fileUrl])
        #expect(request.addDirs == [resource.folderUrl])
        // The read-only review Session is granted the propose-issue tool.
        let server = try #require(request.mcpServers.first)
        #expect(server.tools == ["propose_issue"])
        #expect(server.command == "/path/to/Hercules")
        #expect(server.args.contains("--propose"))
        #expect(server.args.contains("--mcp-issue-server"))
        #expect(server.args.contains(workflowID.uuidString))

        let row = try #require(try Self.review(database, workflowID: workflowID, kind: "code-quality"))
        #expect(row.status == "reviewed")
        #expect(row.summary == "The code reads cleanly.")
        #expect(row.failureReason == nil)
        #expect(row.sessionID == UUID(100))
    }

    @Test("Records failed with the reason when the review Turn throws")
    func marksFailedOnThrow() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.agentClient.start = { @Sendable _ in throw AgentError.cancelled }
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }

        await Self.runScoped(model, .codeQuality)

        let row = try #require(try Self.review(database, workflowID: workflowID, kind: "code-quality"))
        #expect(row.status == "failed")
        #expect(row.summary == nil)
        #expect(row.failureReason == AgentError.cancelled.localizedDescription)
    }

    @Test("Cancelling a live run leaves the review failed with an Interrupted reason")
    func cancelAllInterruptsLiveRun() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)
        let started = LockIsolated(false)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.agentClient.start = { @Sendable _ in
                started.setValue(true)
                // Hang until cancelled, so cancelAll has a live Turn to interrupt.
                try await Task.sleep(for: .seconds(60))
                return try await Self.startSession(for: nil, id: UUID(100), finalAnswer: "")
            }
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }

        // Create the run task inside a uuid scope so its Store writes resolve `\.uuid` (production uses
        // the globally-prepared live generator; tests forbid that fallback).
        let task: Task<Void, Never>? = await withDependencies {
            $0.uuid = .incrementing
        } operation: {
            model.run(.codeQuality)
            // Wait until the run has reached the (hanging) Turn before cancelling.
            while !started.value { await Task.yield() }
            return model.runTasks.withValue { $0[.codeQuality] }
        }
        model.cancelAll()
        await task?.value

        let row = try #require(try Self.review(database, workflowID: workflowID, kind: "code-quality"))
        #expect(row.status == "failed")
        #expect(row.failureReason?.contains("Interrupted") == true)
    }

    @Test("Code Quality and Security run concurrently, each producing its own Summary")
    func concurrentPersonasProduceSeparateSummaries() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)
        let nextSessionID = LockIsolated(100)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                // Distinguish the two Personas by their skill file so each gets its own Summary.
                let isSecurity = request.skillFiles.contains { $0.path.contains("review-security") }
                let summary = isSecurity ? "No security issues found." : "The code reads cleanly."
                let id = nextSessionID.withValue { value -> Int in value += 1; return value }
                return try await Self.startSession(for: request, id: UUID(id), finalAnswer: summary)
            }
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }

        // Start both at once; both tasks share the run map, neither blocks the other.
        await withDependencies {
            $0.uuid = .incrementing
        } operation: {
            model.run(.codeQuality)
            model.run(.security)
            let tasks = model.runTasks.withValue { Array($0.values) }
            for task in tasks { await task.value }
        }

        let codeQuality = try #require(try Self.review(database, workflowID: workflowID, kind: "code-quality"))
        let security = try #require(try Self.review(database, workflowID: workflowID, kind: "security"))
        #expect(codeQuality.status == "reviewed")
        #expect(security.status == "reviewed")
        #expect(codeQuality.summary == "The code reads cleanly.")
        #expect(security.summary == "No security issues found.")
        // Distinct rows, distinct linked Sessions.
        #expect(codeQuality.id != security.id)
        #expect(codeQuality.sessionID != security.sessionID)
    }

    @Test("Stale running rows are reconciled to failed on first refresh (window open)")
    func reconcilesStaleRunningOnOpen() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedReview(database, workflowID: workflowID, kind: "code-quality", status: "running")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }
        await model.refresh()

        let row = try #require(try Self.review(database, workflowID: workflowID, kind: "code-quality"))
        #expect(row.status == "failed")
        #expect(row.failureReason?.isEmpty == false)
    }

    // MARK: - Open Pull Request

    @Test("PR opens only when every non-deleted Issue is done")
    func prGateRequiresAllIssuesDone() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, status: "done")
        try Self.seedIssue(database, workflowID: workflowID, number: 2, status: "proposed")

        let model = Self.makeModel(database: database, workflowID: workflowID)
        await model.refresh()
        // A proposed Issue is outstanding.
        #expect(model.canOpenPullRequest == false)

        // Deny-equivalent: remove the proposed Issue, leaving only the done one.
        try await database.write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) && $0.number.eq(2) }
                .update { $0.isDeleted = true }
                .execute(db)
        }
        await model.refresh()
        #expect(model.canOpenPullRequest == true)
    }

    @Test("Empty Workflow can't open a PR")
    func prGateRejectsEmpty() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)

        let model = Self.makeModel(database: database, workflowID: workflowID)
        await model.refresh()
        #expect(model.canOpenPullRequest == false)
    }

    @Test("Open Pull Request rebases onto base before pushing, returns the compare URL, and confirms")
    func openPullRequestRebasesThenPushesAndReturnsURL() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)
        let pushed = LockIsolated<URL?>(nil)
        // Records the git steps in call order so we can assert the rebase ran before the push.
        let order = LockIsolated<[String]>([])
        let compareURL = URL(string: "https://github.com/acme/widgets/compare/main...feature?expand=1")!

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.worktreeClient.rebaseOntoBase = { @Sendable _ in order.withValue { $0.append("rebase") } }
            $0.worktreeClient.push = { @Sendable worktree in
                order.withValue { $0.append("push") }
                pushed.setValue(worktree)
            }
            $0.worktreeClient.compareURL = { @Sendable _ in compareURL }
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: URL(fileURLWithPath: "/tmp/worktree"),
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }

        let url = await model.openPullRequest()

        #expect(url == compareURL)
        #expect(order.value == ["rebase", "push"])
        #expect(pushed.value == URL(fileURLWithPath: "/tmp/worktree"))
        #expect(model.pullRequestConfirmation == "Branch pushed — finish on GitHub")
        #expect(model.pullRequestError == nil)
        #expect(model.isOpeningPullRequest == false)
    }

    @Test("A rebase conflict aborts before pushing: no URL, no push, friendly error")
    func openPullRequestConflictDoesNotPush() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)
        let pushed = LockIsolated(false)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.worktreeClient.rebaseOntoBase = { @Sendable _ in
                throw WorktreeError.rebaseConflict(base: "main")
            }
            $0.worktreeClient.push = { @Sendable _ in pushed.setValue(true) }
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }

        let url = await model.openPullRequest()

        #expect(url == nil)
        #expect(pushed.value == false)
        #expect(model.pullRequestConfirmation == nil)
        #expect(model.pullRequestError?.contains("conflicts with `main`") == true)
        #expect(model.isOpeningPullRequest == false)
    }

    @Test("A second concurrent Open Pull Request no-ops; git steps don't double")
    func openPullRequestIsReentrancySafe() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)
        let rebaseCount = LockIsolated(0)
        let pushCount = LockIsolated(0)
        let compareURL = URL(string: "https://github.com/acme/widgets/compare/main...feature?expand=1")!
        // Holds the first call inside its detached rebase so the second call lands while it's in flight.
        let gate = DispatchSemaphore(value: 0)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.worktreeClient.rebaseOntoBase = { @Sendable _ in
                rebaseCount.withValue { $0 += 1 }
                gate.wait()
            }
            $0.worktreeClient.push = { @Sendable _ in pushCount.withValue { $0 += 1 } }
            $0.worktreeClient.compareURL = { @Sendable _ in compareURL }
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }

        // First call runs until it suspends inside the (gated) detached rebase, flag now set.
        let first = Task { await model.openPullRequest() }
        while rebaseCount.value < 1 { await Task.yield() }

        // Second call sees the in-flight flag and no-ops without touching git.
        let second = await model.openPullRequest()
        #expect(second == nil)

        gate.signal()
        let firstURL = await first.value

        #expect(firstURL == compareURL)
        #expect(rebaseCount.value == 1)
        #expect(pushCount.value == 1)
        #expect(model.isOpeningPullRequest == false)
    }

    @Test("A failed push surfaces an error and no URL")
    func openPullRequestSurfacesPushError() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.worktreeClient.push = { @Sendable _ in throw WorktreeError.unsupportedRemote("nope") }
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }

        let url = await model.openPullRequest()

        #expect(url == nil)
        #expect(model.pullRequestError != nil)
        #expect(model.pullRequestConfirmation == nil)
    }

    // MARK: - Helpers

    private static func makeModel(database: any DatabaseWriter, workflowID: UUID) -> ValidateModel {
        withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory,
                mcpServerCommand: "/path/to/Hercules"
            )
        }
    }

    private static func seedIssue(
        _ database: any DatabaseWriter, workflowID: UUID, number: Int, status: String
    ) throws {
        try database.write { db in
            try IssueRow.insert {
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: number, title: "Issue \(number)",
                    status: status, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    /// Runs a Persona inside a uuid scope (so the Store writes resolve `\.uuid`, which the live generator
    /// supplies in production but tests forbid) and awaits the run task to completion.
    private static func runScoped(_ model: ValidateModel, _ persona: ReviewPersona) async {
        let task: Task<Void, Never>? = await withDependencies {
            $0.uuid = .incrementing
        } operation: {
            model.run(persona)
            return model.runTasks.withValue { $0[persona] }
        }
        await task?.value
    }

    /// Stands in for the live client's `start`, recording the `validate` Session and a Turn carrying the
    /// final answer the model captures as the Summary. `request` is optional so a hanging stub can pass nil.
    private static func startSession(
        for request: StartRequest?, id: UUID, finalAnswer: String
    ) async throws -> Session {
        if let request {
            try await request.database.write { db in
                try SessionRow.insert {
                    SessionRow(
                        id: id, workflowID: request.workflowID, worktreePath: request.worktree.path,
                        mode: request.mode.rawValue, kind: request.kind.rawValue,
                        issueNumber: nil, createdAt: fixedDate, updatedAt: fixedDate
                    )
                }
                .execute(db)
                try TurnRow.insert {
                    TurnRow(
                        id: UUID(), sessionID: id, userPrompt: request.prompt,
                        finalAnswer: finalAnswer, createdAt: fixedDate, updatedAt: fixedDate
                    )
                }
                .execute(db)
            }
            return Session(
                id: Session.ID(rawValue: id), worktree: request.worktree, mode: request.mode,
                kind: request.kind, skillFiles: request.skillFiles, addDirs: request.addDirs,
                mcpServers: request.mcpServers
            )
        }
        return Session(
            id: Session.ID(rawValue: id), worktree: FileManager.default.temporaryDirectory,
            mode: .readOnly, kind: .validate
        )
    }

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidateModelTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }

    private static func seedWorkflow(_ database: any DatabaseWriter, workflowID: UUID) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
        }
    }

    private static func seedReview(
        _ database: any DatabaseWriter, workflowID: UUID, kind: String, status: String
    ) throws {
        try database.write { db in
            try ReviewRow.insert {
                ReviewRow(
                    id: UUID(), workflowID: workflowID, kind: kind, status: status,
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func review(
        _ database: any DatabaseWriter, workflowID: UUID, kind: String
    ) throws -> ReviewRow? {
        try database.read { db in
            try ReviewRow
                .where { $0.workflowID.eq(workflowID) && $0.kind.eq(kind) }
                .fetchOne(db)
        }
    }
}
