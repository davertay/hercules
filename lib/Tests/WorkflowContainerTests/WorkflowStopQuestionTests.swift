import Agent
import Clocks
import Dependencies
import Foundation
import SQLiteData
import Store
import Testing
import Validate

@testable import Allocate
@testable import Chat
@testable import Design
@testable import WorkflowContainer

/// What the toolbar's Stop does to a Session that is blocked on a question.
///
/// The card's own Cancel and this are meant to be indistinguishable from where the agent sits — a
/// dismissal on the call it is waiting in, then a stopped Turn — and to differ only in how much else
/// goes down with them. These drive the real ``WorkflowContainerModel/stopAll()``, so the routing that
/// makes that true is the thing under test rather than a stand-in for it.
@MainActor
@Suite("Workflow-wide Stop — a Session blocked on a question")
struct WorkflowStopQuestionTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static let question = Question(
        header: "Storage",
        question: "How should offline notes be stored?",
        options: [Question.Option(label: "Use SQLite", description: "A real database")]
    )

    /// Two Chat Phases blocked at once, stopped with one press.
    ///
    /// Both calls are answered on the way down, before either Turn is touched, so each returns its own
    /// error-flagged result and the Harness records a complete call-and-result pair. Both then wait out
    /// the *same* grace: one deadline passing ends both Turns, where a Stop that resolved them one after
    /// the other would still have the second Session blocked here.
    @Test
    func stopAllDeclinesEveryPendingQuestionThenStopsEveryTurnOnOneDeadline() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let directory = root.appending(component: id.uuidString)
        try FileManager.default.createDirectory(
            at: workflowWorktree(in: directory), withIntermediateDirectories: true
        )

        let clock = TestClock()
        let delivered = LockIsolated<[SessionKind: Answer]>([:])
        let stopped = LockIsolated<Set<SessionKind>>([])

        try await withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.continuousClock = clock
            $0.agentClient.start = { @Sendable request in
                let onQuestion = try #require(request.onQuestion)
                let kind = request.kind
                let answer = await onQuestion([Self.question])
                delivered.withValue { $0[kind] = answer }
                // The Turn runs on after the call comes back with its result, as a real one does.
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    stopped.withValue { _ = $0.insert(kind) }
                    throw error
                }
                throw CancellationError()
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
        } operation: {
            let model = WorkflowContainerModel(
                data: WorkflowWindowData(id: id, directory: directory, repoPath: "/repo")
            )
            let design = try #require(model.designModel)
            let allocate = try #require(model.allocateModel)

            design.engine.draftText = "design the sync"
            design.engine.submit()
            allocate.engine.draftText = "carve it up"
            allocate.engine.submit()
            await Self.waitUntil {
                design.engine.pendingQuestion != nil && allocate.engine.pendingQuestion != nil
            }
            #expect(model.isRunning)

            model.stopAll()

            // The Workflow reads as stopped at once, while both Turns are still unwinding behind it.
            #expect(model.isIdle)
            #expect(design.engine.pendingQuestion == nil)
            #expect(allocate.engine.pendingQuestion == nil)

            // Answered first, both of them, and both Turns still alive to record the result.
            await Self.waitUntil { delivered.value.count == 2 }
            #expect(delivered.value == [.design: .cancelled, .allocate: .cancelled])
            #expect(stopped.value.isEmpty)

            // One deadline, shared between them.
            await clock.advance(by: ChatEngine.declinedQuestionGrace)
            for engine in [design.engine, allocate.engine] {
                await engine.stopTask?.value
                await engine.runTask?.value
            }
            #expect(stopped.value == [.design, .allocate])
        }
    }

    /// Cancel's blast radius. Declining a Design question stops that Session's Turn and reaches nothing
    /// else — the Validate Persona the user left reviewing is still reviewing, which is the whole
    /// difference between the card's control and the toolbar's.
    @Test
    func cancellingADesignQuestionLeavesTheOtherPhasesRunning() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(0)
        let directory = root.appending(component: id.uuidString)
        try FileManager.default.createDirectory(
            at: workflowWorktree(in: directory), withIntermediateDirectories: true
        )

        let clock = TestClock()
        let delivered = LockIsolated<Answer?>(nil)

        try await withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.continuousClock = clock
            $0.agentClient.start = { @Sendable request in
                // Only the attended chat Turn is offered an answer; a Validate Persona is not, so it has
                // nothing to block on and simply runs.
                if let onQuestion = request.onQuestion {
                    let answer = await onQuestion([Self.question])
                    delivered.setValue(answer)
                }
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
            $0.agentClient.send = { @Sendable _ in throw CancellationError() }
        } operation: {
            let model = WorkflowContainerModel(
                data: WorkflowWindowData(id: id, directory: directory, repoPath: "/repo")
            )
            let design = try #require(model.designModel)
            let validate = try #require(model.validateModel)
            let database = try #require(model.database)
            try Self.seedWorkflow(database, workflowID: id)

            validate.run(.codeQuality)
            design.engine.draftText = "design the sync"
            design.engine.submit()
            await Self.waitUntil { validate.isAnyRunning && design.engine.pendingQuestion != nil }

            try #require(design.engine.pendingQuestion).cancel()
            await clock.advance(by: ChatEngine.declinedQuestionGrace)
            await design.engine.stopTask?.value
            await design.engine.runTask?.value

            #expect(delivered.value == .cancelled)
            #expect(!design.isBusy)
            // The Workflow is still running, because the Phase the user didn't touch still is.
            #expect(validate.isAnyRunning)
            #expect(model.isRunning)

            validate.cancelAll()
            await Self.waitUntil { !validate.isAnyRunning }
        }
    }

    // MARK: - Helpers

    /// Polls `condition`, yielding between checks so the MainActor run tasks can make progress.
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
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

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowStopQuestionTests-\(UUID().uuidString)", isDirectory: true)
    }
}
