import Agent
import Dependencies
import Foundation
import IssueGraph
import Material
import SQLiteData
import Store
import Testing

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
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory)
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
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory)
        }

        let issue = try #require(try Self.issue(database, workflowID: workflowID, number: 1))
        await model.runIssue(issue)

        #expect(try Self.status(database, workflowID: workflowID, number: 1) == "failed")
    }

    // MARK: - Helpers

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
            try TurnRow.insert {
                TurnRow(
                    id: UUID(200), sessionID: id, userPrompt: request.prompt,
                    finalAnswer: "", createdAt: fixedDate, updatedAt: fixedDate
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
