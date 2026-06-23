import Agent
import Dependencies
import Foundation
import Material
import SQLiteData
import Store
import Testing

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
                worktree: FileManager.default.temporaryDirectory
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
        #expect(request.mcpServers.isEmpty)

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
                worktree: FileManager.default.temporaryDirectory
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
                worktree: FileManager.default.temporaryDirectory
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

    @Test("Stale running rows are reconciled to failed when the window opens")
    func reconcilesStaleRunningOnOpen() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedReview(database, workflowID: workflowID, kind: "code-quality", status: "running")

        _ = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
        } operation: {
            ValidateModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory
            )
        }

        let row = try #require(try Self.review(database, workflowID: workflowID, kind: "code-quality"))
        #expect(row.status == "failed")
        #expect(row.failureReason?.isEmpty == false)
    }

    // MARK: - Helpers

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
                        id: UUID(200), sessionID: id, userPrompt: request.prompt,
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
