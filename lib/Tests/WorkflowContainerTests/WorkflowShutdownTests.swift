import Agent
import Clocks
import Dependencies
import Foundation
import SQLiteData
import Store
import Testing

@testable import Chat
@testable import Design
@testable import WorkflowContainer

/// What quitting the app does to the Workflows it leaves behind.
///
/// Until a tool could block on a question this hardly mattered: a quit orphaned whatever Harnesses were
/// mid-Turn and each of them ended on its own soon enough. A Turn suspended in a question does not end on
/// its own, so quitting now goes through ``OpenWorkflowRegistry/shutDownEverything()`` — the one place
/// that can reach every open Workflow — and waits for the agents to actually be gone before it lets the
/// app go. These drive that method itself; the delegate above it only decides whether to defer the quit
/// and then calls this.
@MainActor
@Suite("Quitting with agents running")
struct WorkflowShutdownTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static let question = Question(
        header: "Storage",
        question: "How should offline notes be stored?",
        options: [Question.Option(label: "Use SQLite", description: "A real database")]
    )

    /// Two Workflows open, both blocked on a question, and one quit.
    ///
    /// Each waiting call is answered on the way down, so each Harness records a complete call-and-result
    /// pair rather than being torn down mid-call, and both Turns are stopped by the time the shutdown
    /// returns — which is what makes it safe for the quit to go through afterwards. Nothing is left
    /// holding a conversation nobody can see.
    @Test
    func quittingDeclinesEveryPendingQuestionAndWaitsForTheAgentsToGo() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let declined = LockIsolated<[UUID: Answer]>([:])
        let stopped = LockIsolated<Set<UUID>>([])

        try await withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.continuousClock = ImmediateClock()
            $0.agentClient.start = { @Sendable request in
                let onQuestion = try #require(request.onQuestion)
                let workflowID = request.workflowID
                let answer = await onQuestion([Self.question])
                declined.withValue { $0[workflowID] = answer }
                // The Turn runs on after the call comes back with its result, as a real one does: it is
                // the stop that ends it, not the answer.
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    stopped.withValue { _ = $0.insert(workflowID) }
                    throw error
                }
                throw CancellationError()
            }
        } operation: {
            let registry = OpenWorkflowRegistry()
            let ids = [UUID(0), UUID(1)]
            let workflows = try ids.map { try Self.makeModel(id: $0, root: root, registry: registry) }
            let engines = try workflows.map { try #require($0.designModel).engine }

            for engine in engines {
                engine.draftText = "design the sync"
                engine.submit()
            }
            await Self.waitUntil {
                ids.allSatisfy(registry.isOpen) && engines.allSatisfy { $0.pendingQuestion != nil }
            }
            #expect(registry.hasWorkInFlight)

            await registry.shutDownEverything()

            // Answered, both of them, and both Turns stopped — before the quit this is holding open was
            // ever allowed to proceed.
            #expect(declined.value == [ids[0]: .cancelled, ids[1]: .cancelled])
            #expect(stopped.value == Set(ids))
            #expect(engines.allSatisfy { $0.pendingQuestion == nil })
            #expect(!registry.hasWorkInFlight)
            #expect(workflows.allSatisfy { $0.isIdle })
        }
    }

    /// The drain is bounded, so a Harness that won't come down when it's asked to delays the quit and
    /// can't prevent it.
    ///
    /// The agent here ignores its cancellation entirely — the one case where waiting for the work to
    /// finish would mean waiting forever. A real one that behaved this way would be killed a moment later
    /// by the teardown that signalled it, but that moment is longer than anyone should be kept waiting on
    /// a quit, so the shutdown gives up and returns with the work still in flight rather than holding the
    /// app open for it.
    @Test(.timeLimit(.minutes(1)))
    func aWorkflowThatWontComeDownIsGivenUpOnRatherThanWaitedForever() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let released = LockIsolated(false)

        try await withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.continuousClock = ImmediateClock()
            $0.agentClient.start = { @Sendable _ in
                // Deaf to cancellation, and only this test can end it.
                while !released.value { await Task.yield() }
                throw CancellationError()
            }
        } operation: {
            let registry = OpenWorkflowRegistry()
            let id = UUID(0)
            let workflow = try Self.makeModel(id: id, root: root, registry: registry)
            let engine = try #require(workflow.designModel).engine

            engine.draftText = "design the sync"
            engine.submit()
            await Self.waitUntil { registry.isOpen(id) && engine.hasTurnInFlight }

            // Returns at all, which is the whole assertion — and returns with the work still running,
            // so it gave up rather than got what it was waiting for.
            await registry.shutDownEverything()
            #expect(registry.hasWorkInFlight)

            released.setValue(true)
            await engine.runTask?.value
            #expect(!registry.hasWorkInFlight)
        }
    }

    /// The ordinary quit, with nothing running, waits for nothing at all — this is the state the delegate
    /// reads to terminate on the spot instead of deferring.
    @Test
    func anIdleWorkflowIsNotSomethingAQuitHasToWaitFor() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = OpenWorkflowRegistry()
        let id = UUID(0)
        let workflow = try Self.makeModel(id: id, root: root, registry: registry)
        await Self.waitUntil { registry.isOpen(id) }

        #expect(workflow.isIdle)
        #expect(!registry.hasWorkInFlight)
        await registry.shutDownEverything()
        #expect(!registry.hasWorkInFlight)
    }

    /// A stopped Turn is still a running agent until it has finished unwinding, and that — not the flag
    /// the UI reads — is what a quit waits on.
    ///
    /// ``WorkflowContainerModel/isRunning`` goes false the moment Stop is pressed so the stop shows on
    /// screen at once. A quit that took that for its answer would let the app go while the Harness behind
    /// it was still coming down, orphaning the very process the shutdown exists to collect.
    @Test
    func aStoppedTurnStillCountsAsWorkInFlightUntilItHasActuallyUnwound() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = TestClock()
        let released = LockIsolated(false)

        try await withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.continuousClock = clock
            $0.agentClient.start = { @Sendable _ in
                while !released.value { await Task.yield() }
                throw CancellationError()
            }
        } operation: {
            let registry = OpenWorkflowRegistry()
            let id = UUID(0)
            let workflow = try Self.makeModel(id: id, root: root, registry: registry)
            let engine = try #require(workflow.designModel).engine

            engine.draftText = "design the sync"
            engine.submit()
            await Self.waitUntil { registry.isOpen(id) && engine.hasTurnInFlight }

            workflow.stopAll()

            // The Workflow reads as stopped, and the Turn behind it has not gone anywhere yet.
            #expect(workflow.isIdle)
            #expect(workflow.hasWorkInFlight)
            #expect(registry.hasWorkInFlight)

            released.setValue(true)
            await engine.runTask?.value
            #expect(!registry.hasWorkInFlight)
        }
    }

    /// A Session whose question the quit abandoned is a Session the user can carry straight on with.
    ///
    /// Nothing of the question was ever persisted — it was a blocked call in a process that is now gone —
    /// so there is nothing to resurrect and no card comes back. What is on disk is the Session, and the
    /// next thing the user types resumes it.
    @Test
    func aSessionWhoseQuestionTheQuitAbandonedIsStillResumable() async throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID(100)
        let resumed = LockIsolated<[SendRequest]>([])

        try await withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
            $0.continuousClock = ImmediateClock()
            $0.agentClient.send = { @Sendable request in
                let isFirst = resumed.withValue { requests in
                    requests.append(request)
                    return requests.count == 1
                }
                // The Turn the quit lands on blocks on a question; the one after it just answers.
                guard isFirst, let onQuestion = request.onQuestion else { return request.session }
                _ = await onQuestion([Self.question])
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
        } operation: {
            let registry = OpenWorkflowRegistry()
            let id = UUID(0)
            let workflow = try Self.makeModel(id: id, root: root, registry: registry)
            let design = try #require(workflow.designModel)
            let database = try #require(workflow.database)
            try Self.seedSession(database, workflowID: id, sessionID: sessionID)
            try await design.engine.$existingSessionRow.load()

            design.engine.draftText = "design the sync"
            design.engine.submit()
            await Self.waitUntil { registry.isOpen(id) && design.engine.pendingQuestion != nil }

            await registry.shutDownEverything()

            // Nothing left of the question, and nothing that will bring it back: the conversation is
            // simply where it was, with the composer free.
            #expect(design.engine.pendingQuestion == nil)
            #expect(workflow.isIdle)

            design.engine.draftText = "use SQLite"
            #expect(!design.engine.isSendDisabled)
            design.engine.submit()
            await design.engine.runTask?.value

            #expect(design.engine.pendingQuestion == nil)
            #expect(resumed.value.count == 2)
            #expect(resumed.value.last?.prompt == "use SQLite")
            // The same Session as before the quit, resumed rather than started afresh.
            #expect(resumed.value.allSatisfy { $0.session.id.rawValue == sessionID })
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

    private static func makeModel(
        id: UUID, root: URL, registry: OpenWorkflowRegistry
    ) throws -> WorkflowContainerModel {
        let directory = root.appending(component: id.uuidString)
        try FileManager.default.createDirectory(
            at: workflowWorktree(in: directory), withIntermediateDirectories: true
        )
        return WorkflowContainerModel(
            data: WorkflowWindowData(id: id, directory: directory, repoPath: "/repo"),
            registry: registry
        )
    }

    private static func seedSession(
        _ database: any DatabaseWriter, workflowID: UUID, sessionID: UUID
    ) throws {
        try database.write { db in
            try WorkflowRow.upsert {
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

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowShutdownTests-\(UUID().uuidString)", isDirectory: true)
    }
}
