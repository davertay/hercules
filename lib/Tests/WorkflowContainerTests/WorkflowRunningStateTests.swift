import Chat
import Dependencies
import Foundation
import SQLiteData
import Store
import Testing
import Validate

@testable import Allocate
@testable import Design
@testable import Execute
@testable import PRD
@testable import WorkflowContainer

/// The Workflow's single aggregate running state: ``WorkflowContainerModel/isRunning`` is the OR of all
/// five Phases' running signals, and flips as any one of them enters or leaves its running state.
@MainActor
@Suite("Workflow running state")
struct WorkflowRunningStateTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A chat Phase mid-Turn makes the Workflow running, and quiescing returns it to idle")
    func chatPhaseBusyDrivesAggregate() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = Self.makeModel(id: UUID(0), root: root)
        let design = try #require(model.designModel)
        let prd = try #require(model.prdModel)
        let allocate = try #require(model.allocateModel)

        #expect(model.isIdle)
        #expect(!model.isRunning)

        // Each chat Phase's `isBusy` reflects its engine's run flag; flipping any one flips the aggregate.
        for engine in [design.engine, prd.engine, allocate.engine] {
            engine.isRunning = true
            #expect(model.isRunning)
            #expect(!model.isIdle)
            engine.isRunning = false
            #expect(model.isIdle)
        }
    }

    @Test("An in-flight Execute run makes the Workflow running until it stops")
    func executeRunDrivesAggregate() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let directory = root.appending(component: id.uuidString)
        try FileManager.default.createDirectory(
            at: workflowWorktree(in: directory), withIntermediateDirectories: true
        )

        // The run loop and its behind-the-scenes Store writes read dependencies at call time, so the whole
        // run lives inside the scope that overrides them.
        try await withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            // The run hangs on a cancellable sleep so the Phase stays running until we stop it.
            $0.agentClient.start = { @Sendable _ in
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
        } operation: {
            let model = WorkflowContainerModel(
                data: WorkflowWindowData(id: id, directory: directory, repoPath: "/repo")
            )
            let execute = try #require(model.executeModel)
            let database = try #require(model.database)
            try Self.seedReadyIssue(database, workflowID: id)
            try await execute.$issues.load()

            #expect(model.isIdle)

            execute.start()
            await Self.waitUntil { execute.isRunning }
            #expect(model.isRunning)
            #expect(!model.isIdle)

            execute.cancelRun()
            await execute.runTask.value?.value
            #expect(model.isIdle)
        }
    }

    @Test("A running Validate review makes the Workflow running until it stops")
    func validateReviewDrivesAggregate() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let directory = root.appending(component: id.uuidString)
        try FileManager.default.createDirectory(
            at: workflowWorktree(in: directory), withIntermediateDirectories: true
        )

        // A review writes its status through the Store, which reads dependencies at call time, so the whole
        // run lives inside the scope that overrides them.
        try await withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.agentClient.start = { @Sendable _ in
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
        } operation: {
            let model = WorkflowContainerModel(
                data: WorkflowWindowData(id: id, directory: directory, repoPath: "/repo")
            )
            let validate = try #require(model.validateModel)
            let database = try #require(model.database)
            try Self.seedWorkflow(database, workflowID: id)

            #expect(model.isIdle)

            validate.run(.codeQuality)
            await Self.waitUntil { validate.isAnyRunning }
            #expect(model.isRunning)
            #expect(!model.isIdle)

            validate.cancelAll()
            await Self.waitUntil { !validate.isAnyRunning }
            #expect(model.isIdle)
        }
    }

    @Test("stopAll cancels in-flight work across every Phase, returning the Workflow to idle")
    func stopAllCancelsEveryPhase() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let directory = root.appending(component: id.uuidString)
        try FileManager.default.createDirectory(
            at: workflowWorktree(in: directory), withIntermediateDirectories: true
        )

        // Every Phase's agent and its Store writes read dependencies at call time, so all the in-flight
        // work lives inside the scope that overrides them.
        try await withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            // Each started agent hangs on a cancellable sleep so its Phase stays running until stopAll.
            $0.agentClient.start = { @Sendable _ in
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
        } operation: {
            let model = WorkflowContainerModel(
                data: WorkflowWindowData(id: id, directory: directory, repoPath: "/repo")
            )
            let design = try #require(model.designModel)
            let execute = try #require(model.executeModel)
            let validate = try #require(model.validateModel)
            let database = try #require(model.database)
            try Self.seedReadyIssue(database, workflowID: id)
            try await execute.$issues.load()

            #expect(model.isIdle)

            // Light up a chat Phase mid-Turn, the Execute run loop, and a Validate Persona at once.
            design.engine.draftText = "design something"
            design.engine.submit()
            execute.start()
            validate.run(.codeQuality)
            await Self.waitUntil { execute.isRunning && validate.isAnyRunning }
            #expect(model.isRunning)
            #expect(!model.isIdle)

            // One press stops everything across all five Phases.
            model.stopAll()
            await design.engine.runTask?.value
            await execute.runTask.value?.value
            await Self.waitUntil { model.isIdle }
            #expect(model.isIdle)
        }
    }

    // MARK: - Helpers

    /// Polls `condition`, yielding between checks so the MainActor run task can make progress.
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    private static func makeModel(id: UUID, root: URL) -> WorkflowContainerModel {
        withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = fixedDate
        } operation: {
            WorkflowContainerModel(
                data: WorkflowWindowData(
                    id: id,
                    directory: root.appending(component: id.uuidString),
                    repoPath: "/repo"
                )
            )
        }
    }

    private static func seedWorkflow(_ database: any DatabaseWriter, workflowID: UUID) throws {
        try database.write { db in
            try WorkflowRow.upsert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
        }
    }

    private static func seedReadyIssue(_ database: any DatabaseWriter, workflowID: UUID) throws {
        try seedWorkflow(database, workflowID: workflowID)
        try database.write { db in
            try IssueRow.insert {
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: 1, title: "Issue 1",
                    body: "Implement 1.", dependencies: [], status: "new",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowRunningStateTests-\(UUID().uuidString)", isDirectory: true)
    }
}
