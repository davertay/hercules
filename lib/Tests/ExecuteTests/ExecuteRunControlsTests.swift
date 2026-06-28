import Agent
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

/// Exercises the Execute Phase's Run/Stop lifecycle (`start`, `stop`, `canRun`, `isRunning`) over the
/// `run()` loop.
@MainActor
@Suite("ExecuteModel run controls")
struct ExecuteRunControlsTests {

    @Test("canRun is true for a valid, non-empty, idle graph")
    func canRunWhenValid() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])

        let model = Self.model(database: database, workflowID: workflowID) { request in
            try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        #expect(model.canRun == true)
        #expect(model.isRunning == false)
    }

    @Test("canRun is false when the graph fails validation")
    func canRunFalseForInvalidGraph() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        // #1 depends on #99, which doesn't exist — an unknown-dependency validation failure.
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [99])

        let model = Self.model(database: database, workflowID: workflowID) { request in
            try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        #expect(model.validationError != nil)
        #expect(model.canRun == false)
    }

    @Test("canRun is false when there are no Issues")
    func canRunFalseWhenEmpty() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)

        let model = Self.model(database: database, workflowID: workflowID) { request in
            try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        #expect(model.isEmpty == true)
        #expect(model.canRun == false)
    }

    @Test("start drives the whole run to completion, then clears the run state")
    func startRunsToCompletion() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let model = Self.model(database: database, workflowID: workflowID) { request in
            try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        model.start()
        await model.runTask.value?.value

        #expect(model.isRunning == false)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "done")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "done")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == true)
    }

    @Test("start is a no-op while a run is already in flight")
    func startIgnoredWhileRunning() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])

        let starts = LockIsolated(0)
        let model = Self.model(database: database, workflowID: workflowID) { request in
            starts.withValue { $0 += 1 }
            // Block until cancelled so the first run stays in flight across the second start attempt.
            try await Task.sleep(for: .seconds(60))
            return try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        model.start()
        await Self.waitUntil { model.isRunning && starts.value == 1 }

        model.start()
        #expect(starts.value == 1)

        model.stop()
        await model.runTask.value?.value
    }

    @Test("stop cancels the in-flight run, marking the worked Issue failed and clearing the run state")
    func stopCancelsAndFailsWorkedIssue() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let model = Self.model(database: database, workflowID: workflowID) { request in
            // Block on a cancellable sleep, standing in for a Turn that runs until the Harness is torn
            // down; cancellation throws, as the live client does.
            _ = try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
            try await Task.sleep(for: .seconds(60))
            return try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        model.start()
        await Self.waitUntil { Self.statusOrNil(database, workflowID: workflowID, number: 1) == "in_progress" }

        model.stop()
        await model.runTask.value?.value

        #expect(model.isRunning == false)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "new")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == false)
    }

    @Test("cancelRun ends an in-flight run, standing in for the window-close teardown path")
    func cancelRunEndsInFlightRun() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])

        let model = Self.model(database: database, workflowID: workflowID) { request in
            _ = try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
            try await Task.sleep(for: .seconds(60))
            return try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        model.start()
        await Self.waitUntil { Self.statusOrNil(database, workflowID: workflowID, number: 1) == "in_progress" }

        // The window's deinit routes here on close/quit.
        model.cancelRun()
        await model.runTask.value?.value

        #expect(model.isRunning == false)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
    }

    // MARK: - Helpers

    /// Polls `condition`, yielding between checks so the MainActor run task can make progress.
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    private static func model(
        database: any DatabaseWriter,
        workflowID: UUID,
        start: @escaping @Sendable (StartRequest) async throws -> Session
    ) -> ExecuteModel {
        let head = LockIsolated(0)
        return withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.uuid = .incrementing
            $0.agentClient.start = start
            $0.agentClient.send = { @Sendable _ in
                Issue.record("Execute run must not resume a Session")
                throw CancellationError()
            }
            // HEAD advances per call so a non-throwing run looks committed and reaches `done`; the
            // cancellation tests throw out of `start`, so the commit gate is never the deciding factor.
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }
    }

    private static func startSession(for request: StartRequest, id: UUID) async throws -> Session {
        try await request.database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: id, workflowID: request.workflowID, worktreePath: request.worktree.path,
                    mode: request.mode.rawValue, kind: request.kind.rawValue,
                    issueNumber: request.issueNumber, createdAt: fixedDate, updatedAt: fixedDate
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

    private static func seedWorkflow(_ database: any DatabaseWriter, workflowID: UUID) throws {
        try database.write { db in
            try WorkflowRow
                .upsert {
                    WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
                }
                .execute(db)
        }
    }

    private static func seedIssue(
        _ database: any DatabaseWriter,
        workflowID: UUID,
        number: Int,
        dependencies: [Int],
        status: String = "new"
    ) throws {
        try seedWorkflow(database, workflowID: workflowID)
        try database.write { db in
            try IssueRow.insert {
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: number, title: "Issue \(number)",
                    body: "Implement \(number).", dependencies: dependencies, status: status,
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func status(
        _ database: any DatabaseWriter, workflowID: UUID, number: Int
    ) throws -> String? {
        try database.read { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) && $0.number.eq(number) }
                .fetchOne(db)
        }?.status
    }

    /// Non-throwing status read for poll predicates.
    private static func statusOrNil(
        _ database: any DatabaseWriter, workflowID: UUID, number: Int
    ) -> String? {
        try? status(database, workflowID: workflowID, number: number)
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
            .appendingPathComponent("ExecuteRunControlsTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }
}
