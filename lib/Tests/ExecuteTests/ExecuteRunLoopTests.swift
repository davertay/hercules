import Agent
import Dependencies
import Foundation
import IssueGraph
import Material
import SQLiteData
import Store
import Testing
import Worktree

@testable import Execute

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

/// Exercises `ExecuteModel.run` with the agent client stubbed so each Issue's run is a synchronous
/// success/failure decision.
@MainActor
@Suite("ExecuteModel.run")
struct ExecuteRunLoopTests {

    @Test("Runs Issues in dependency (ready) order, lowest number first")
    func runsInReadyOrder() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        // A chain 1 → 2 → 3, so each unlocks the next only once it is `done`.
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])
        try Self.seedIssue(database, workflowID: workflowID, number: 3, dependencies: [2])

        let order = LockIsolated<[Int]>([])
        let model = Self.model(database: database, workflowID: workflowID) { request in
            order.withValue { $0.append(request.issueNumber ?? -1) }
            return try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        await model.run()

        #expect(order.value == [1, 2, 3])
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "done")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "done")
        #expect(try Self.status(database, workflowID: workflowID, number: 3) == "done")
    }

    @Test("Skips an Issue whose dependency hasn't completed (only ready Issues run)")
    func selectsLowestReadyNotLowestNumber() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        // #1 depends on #2, so the lowest *ready* Issue is #2 despite #1's lower number.
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [2])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [])

        let order = LockIsolated<[Int]>([])
        let model = Self.model(database: database, workflowID: workflowID) { request in
            order.withValue { $0.append(request.issueNumber ?? -1) }
            return try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        await model.run()

        #expect(order.value == [2, 1])
    }

    @Test("Halts on the first failure: the failed Issue stays failed, the rest stay new, Phase incomplete")
    func haltsOnFirstFailure() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])
        try Self.seedIssue(database, workflowID: workflowID, number: 3, dependencies: [2])

        let order = LockIsolated<[Int]>([])
        let model = Self.model(database: database, workflowID: workflowID) { request in
            order.withValue { $0.append(request.issueNumber ?? -1) }
            _ = try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
            if request.issueNumber == 2 { throw AgentError.cancelled }
            return Session(
                id: Session.ID(rawValue: UUID(100 + (request.issueNumber ?? 0))),
                worktree: request.worktree, mode: request.mode, kind: request.kind,
                skillFiles: request.skillFiles, addDirs: request.addDirs, mcpServers: request.mcpServers
            )
        }

        await model.run()

        #expect(order.value == [1, 2])
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "done")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "failed")
        #expect(try Self.status(database, workflowID: workflowID, number: 3) == "new")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == false)
    }

    @Test("Reconciles a stale in_progress Issue to failed at run start, then halts")
    func reconcilesStaleInProgressBeforeSelecting() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        // #1 was left `in_progress` by a crash; #2 depends on it.
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [], status: "in_progress")
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let order = LockIsolated<[Int]>([])
        let model = Self.model(database: database, workflowID: workflowID) { request in
            order.withValue { $0.append(request.issueNumber ?? -1) }
            return try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        await model.run()

        // Demoted to `failed` before selection, so nothing was ready and no Issue ran.
        #expect(order.value == [])
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "new")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == false)
    }

    @Test("Completing every Issue marks the Execute Phase complete, unlocking Validate")
    func completionUnlocksValidate() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [])
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let model = Self.model(database: database, workflowID: workflowID) { request in
            try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        await model.run()

        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "done")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "done")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == true)
    }

    @Test("Re-running after a partial run skips already-done Issues and completes the rest")
    func rerunSkipsDoneIssues() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        // #1 already landed in a prior run; #2 depends on it and is still `new`.
        try Self.seedIssue(database, workflowID: workflowID, number: 1, dependencies: [], status: "done")
        try Self.seedIssue(database, workflowID: workflowID, number: 2, dependencies: [1])

        let order = LockIsolated<[Int]>([])
        let model = Self.model(database: database, workflowID: workflowID) { request in
            order.withValue { $0.append(request.issueNumber ?? -1) }
            return try await Self.startSession(for: request, id: UUID(100 + (request.issueNumber ?? 0)))
        }

        await model.run()

        // The already-`done` #1 was skipped.
        #expect(order.value == [2])
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "done")
        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "done")
        #expect(try Self.executeCompleted(database, workflowID: workflowID) == true)
    }

    // MARK: - Helpers

    /// `send` traps so a run never resumes a Session. `headSHA` advances on every call so each Issue's
    /// before/after reads differ — i.e. every successful run looks like it committed, which keeps these
    /// loop tests focused on selection/halt order rather than the commit gate (covered in runIssue tests).
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
                Issue.record("ExecuteModel.run must not resume a Session")
                throw CancellationError()
            }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory)
        }
    }

    /// Stands in for the live client's `start`, recording the `execute` Session as the Agent would.
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

    private static func seedIssue(
        _ database: any DatabaseWriter,
        workflowID: UUID,
        number: Int,
        dependencies: [Int],
        status: String = "new"
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
            .appendingPathComponent("ExecuteRunLoopTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }
}
