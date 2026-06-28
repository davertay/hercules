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

@MainActor
@Suite("ExecuteModel.runIssue")
struct ExecuteRunIssueTests {

    @Test("implement-issue Skill resolves from the bundle")
    func implementIssueSkillResolves() {
        let skill = loadSkill(.implementIssue)
        #expect(skill.name == "implement-issue")
        #expect(skill.fileUrl.path.hasSuffix("skills/implement-issue/SKILL.md"))
        #expect(skill.folderUrl == skill.fileUrl.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: skill.fileUrl.path))
    }

    @Test("Runs one Issue as a write-mode execute Session and marks it done on success")
    func runsIssueAndMarksDoneOnSuccess() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 2, body: "Implement the thing.")
        let skill = loadSkill(.implementIssue)
        let captured = LockIsolated<StartRequest?>(nil)
        let head = LockIsolated(0)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return try await Self.startSession(for: request, id: UUID(100))
            }
            // A run must never construct a chat engine, so resume must never be reached.
            $0.agentClient.send = { @Sendable _ in
                Issue.record("ExecuteModel.runIssue must not resume a Session")
                throw CancellationError()
            }
            // HEAD advances across the run, standing in for the agent's commit so the gate passes.
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 2))
        await model.runIssue(issue)

        let request = try #require(captured.value)
        #expect(request.mode == .write)
        #expect(request.worktree == FileManager.default.temporaryDirectory)
        #expect(request.workflowID == workflowID)
        #expect(request.kind == .execute)
        #expect(request.issueNumber == 2)
        #expect(request.prompt == "Implement the thing.")
        #expect(request.skillFiles == [skill.fileUrl])
        #expect(request.addDirs == [skill.folderUrl])
        #expect(request.inputs == nil)
        #expect(request.mcpServers.isEmpty)

        // The Session row carries the Issue link, resolved back via the Store helper.
        let session = try #require(try database.session(forIssue: 2, workflowID: workflowID))
        #expect(session.id == UUID(100))
        #expect(session.kind == SessionKind.execute.rawValue)
        #expect(session.issueNumber == 2)

        #expect(try Self.status(database, workflowID: workflowID, number: 2) == "done")
    }

    @Test("Standard mode attaches both the PRD and the Design summary, PRD first")
    func attachesPRDThenDesignSummary() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedIssue(database, workflowID: workflowID, number: 1, body: "Do it.")
        try Self.seedCompletedPhase(
            database, workflowID: workflowID, kind: "prd",
            artifactPath: workflowDirectory.appendingPathComponent("phases/prd/prd.md").path, id: UUID(-2)
        )
        try Self.seedCompletedPhase(
            database, workflowID: workflowID, kind: "design",
            artifactPath: workflowDirectory.appendingPathComponent("phases/design/summary.md").path, id: UUID(-3)
        )
        let captured = LockIsolated<StartRequest?>(nil)
        let head = LockIsolated(0)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return try await Self.startSession(for: request, id: UUID(100))
            }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory, workflowDirectory: workflowDirectory
            )
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        let inputs = try #require(captured.value?.inputs)
        #expect(inputs.root == workflowDirectory)
        #expect(inputs.relativePaths == ["phases/prd/prd.md", "phases/design/summary.md"])
    }

    @Test("Small Job mode (no completed-Phase Artifacts) attaches nothing and still runs the Issue")
    func attachesNothingWhenNoArtifacts() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, body: "Do it.")
        let captured = LockIsolated<StartRequest?>(nil)
        let head = LockIsolated(0)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return try await Self.startSession(for: request, id: UUID(100))
            }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: Self.makeWorkflowDirectory()
            )
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        #expect(captured.value?.inputs == nil)
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "done")
    }

    @Test("Partial: only the present Artifact is attached, the absent one skipped without failing")
    func attachesOnlyPresentArtifact() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedIssue(database, workflowID: workflowID, number: 1, body: "Do it.")
        // PRD present, no design summary (e.g. it was never produced).
        try Self.seedCompletedPhase(
            database, workflowID: workflowID, kind: "prd",
            artifactPath: workflowDirectory.appendingPathComponent("phases/prd/prd.md").path, id: UUID(-2)
        )
        let captured = LockIsolated<StartRequest?>(nil)
        let head = LockIsolated(0)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return try await Self.startSession(for: request, id: UUID(100))
            }
            $0.worktreeClient.headSHA = { @Sendable _ in head.withValue { $0 += 1; return "sha-\($0)" } }
        } operation: {
            ExecuteModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory, workflowDirectory: workflowDirectory
            )
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        let inputs = try #require(captured.value?.inputs)
        #expect(inputs.relativePaths == ["phases/prd/prd.md"])
        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "done")
    }

    @Test("Marks the Issue failed when the Turn errors")
    func marksFailedOnTurnError() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, body: "Do it.")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                // Record the Session, then throw to stand in for an abnormally-terminated Turn.
                _ = try await Self.startSession(for: request, id: UUID(101))
                throw AgentError.cancelled
            }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        let failed = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        #expect(failed.status == "failed")
        // The thrown error's description is captured on the Issue, even though a Turn row exists here it
        // is the runIssue catch — not the transcript — that records the reason.
        #expect(failed.failureReason == AgentError.cancelled.localizedDescription)
    }

    @Test("Marks failed (not done) when the Turn finishes but HEAD didn't move, with the agent's words as reason")
    func marksFailedWhenNoCommitUsingFinalAnswer() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, body: "Do it.")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                try await Self.startSession(
                    for: request, id: UUID(101),
                    finalAnswer: "I'm blocked — the file write operations require your permission."
                )
            }
            // HEAD is constant across the run: the agent committed nothing.
            $0.worktreeClient.headSHA = { @Sendable _ in "same-sha" }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        let failed = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        #expect(failed.status == "failed")
        #expect(failed.failureReason == "I'm blocked — the file write operations require your permission.")
    }

    @Test("No commit and an empty final answer falls back to the clean-tree default reason")
    func marksFailedWhenNoCommitCleanTreeDefaultReason() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, body: "Do it.")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                try await Self.startSession(for: request, id: UUID(101))
            }
            $0.worktreeClient.headSHA = { @Sendable _ in "same-sha" }
            $0.worktreeClient.isDirty = { @Sendable _ in false }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        let failed = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        #expect(failed.status == "failed")
        #expect(failed.failureReason == "The agent produced no commit and made no changes.")
    }

    @Test("No commit but a dirty tree falls back to the committed-nothing default reason")
    func marksFailedWhenNoCommitDirtyTreeDefaultReason() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, body: "Do it.")

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                try await Self.startSession(for: request, id: UUID(101))
            }
            $0.worktreeClient.headSHA = { @Sendable _ in "same-sha" }
            $0.worktreeClient.isDirty = { @Sendable _ in true }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        let failed = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        #expect(failed.status == "failed")
        #expect(
            failed.failureReason
                == "The agent changed files but committed nothing — Execute requires each Issue's work to be committed."
        )
    }

    @Test("Fails closed when HEAD can't be read — an unverifiable run is never done")
    func marksFailedWhenHeadUnreadable() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedIssue(database, workflowID: workflowID, number: 1, body: "Do it.")

        let started = LockIsolated(false)
        let model = withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                started.setValue(true)
                return try await Self.startSession(for: request, id: UUID(101))
            }
            // Reading HEAD throws — we can't confirm work, so the run must not reach `done`.
            $0.worktreeClient.headSHA = { @Sendable _ in throw AgentError.cancelled }
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        let failed = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        #expect(failed.status == "failed")
        #expect(failed.failureReason?.hasPrefix("Couldn't verify the worktree advanced") == true)
        // The pre-run HEAD read failed, so the agent was never started.
        #expect(started.value == false)
    }

    // MARK: - Helpers

    /// Stands in for the live client's `start`, recording the `execute` Session as the Agent would. The
    /// Turn's `finalAnswer` defaults empty; the no-commit tests set it to assert it surfaces as the reason.
    private static func startSession(
        for request: StartRequest, id: UUID, finalAnswer: String = ""
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

    private static func seedIssue(
        _ database: any DatabaseWriter, workflowID: UUID, number: Int, body: String
    ) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try IssueRow.insert {
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: number, title: "Issue \(number)",
                    body: body, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func seedCompletedPhase(
        _ database: any DatabaseWriter, workflowID: UUID, kind: String, artifactPath: String, id: UUID
    ) throws {
        try database.write { db in
            try PhaseRow.insert {
                PhaseRow(
                    id: id, workflowID: workflowID, kind: kind, status: "complete",
                    artifactPath: artifactPath, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    /// A distinct on-disk-style root per test so the relative-path computation has a stable prefix; the
    /// paths need not actually exist — attachment keys off the Phase row, not the filesystem.
    private static func makeWorkflowDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecuteRunIssueTests-WF-\(UUID().uuidString)", isDirectory: true)
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

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecuteRunIssueTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }
}
