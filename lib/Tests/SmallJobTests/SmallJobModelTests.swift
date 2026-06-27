import Agent
import Dependencies
import Foundation
import Material
import SQLiteData
import Store
import Testing

@testable import SmallJob

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
private let mcpServerCommand = "/repo/.build/hercules"

@MainActor
@Suite("SmallJobModel")
struct SmallJobModelTests {

    // MARK: - Material wiring

    @Test
    func smallJobSkillResolvesFromBundle() {
        let skill = loadSkill(.smallJob)
        #expect(skill.name == "small-job")
        #expect(skill.fileUrl.path.hasSuffix("skills/small-job/SKILL.md"))
        #expect(skill.folderUrl == skill.fileUrl.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: skill.fileUrl.path))
    }

    // MARK: - acceptAndWrite

    @Test
    func acceptAndWriteAttachesWriterClearsPriorIssuesAfterSuccessAndCompletesDesignPhase() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        // A prior committed Issue and grill Session, as found when reopening after a prior commit. The grill
        // Session is the `.design` kind the Small Job reuses.
        try Self.seedIssue(database, id: UUID(-10), number: 1, title: "Stale issue")
        try Self.seedSession(database, id: UUID(100))
        let priorLiveAtCommit = LockIsolated<Bool?>(nil)
        let committedServers = LockIsolated<[MCPServer]?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                // Transactional ordering: the prior Issue is still live while the commit Turn runs; it is
                // soft-deleted only once this write has succeeded.
                let priorLive = try await request.database.read { db in
                    try !(IssueRow.find(UUID(-10)).fetchOne(db)?.isDeleted ?? true)
                }
                priorLiveAtCommit.setValue(priorLive)
                committedServers.setValue(request.mcpServers)
                // The MCP child's out-of-process writes are stubbed by seeding fresh rows.
                try await Self.seedIssues(request.database, count: 2)
                return try await Self.resumeSession(for: request, turnID: UUID(201))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        #expect(model.isAcceptAvailable)
        model.acceptAndWrite()
        await model.runTask?.value

        // The prior Issue was still live while the commit Turn ran.
        #expect(priorLiveAtCommit.value == true)
        // The create-issue writer is attached, but only as this commit Turn's per-turn override.
        let databasePath = workflowDirectory.appendingPathComponent("workflow.sqlite").path
        #expect(committedServers.value == [
            MCPServer(
                name: "hercules",
                command: mcpServerCommand,
                args: [
                    "--mcp-issue-server",
                    "--db", databasePath,
                    "--workflow-id", UUID(-1).uuidString,
                ],
                tools: ["create_issue"]
            )
        ])
        // The prior Issue is soft-deleted only after the write succeeded, leaving just the new set.
        let prior = try await database.read { db in try IssueRow.find(UUID(-10)).fetchOne(db) }
        #expect(prior?.isDeleted == true)
        let current = try await database.read { db in
            try WorkflowIssuesRequest(workflowID: UUID(-1)).fetch(db)
        }
        #expect(current.map(\.number) == [1, 2])
        // The Design Phase is complete with a null Artifact path — its rows unlock Execute in Small Job.
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("design") }.fetchOne(db)
        }
        #expect(phase?.status == "complete")
        #expect(phase?.artifactPath == nil)
        #expect(model.engine.errorText == nil)
        #expect(!model.engine.isRunning)
    }

    @Test
    func acceptAndWriteLeavesPriorIssuesIntactWhenCommitTurnThrows() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        try Self.seedIssue(database, id: UUID(-10), number: 1, title: "Good issue")
        try Self.seedSession(database, id: UUID(100))

        struct CommitFailed: Error {}

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable _ in
                // A failed/crashed commit Turn throws out of runTurn before any delete/complete.
                throw CommitFailed()
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.acceptAndWrite()
        await model.runTask?.value

        // The prior set is fully intact, and the Phase is not completed.
        let current = try await database.read { db in
            try WorkflowIssuesRequest(workflowID: UUID(-1)).fetch(db)
        }
        #expect(current.map(\.title) == ["Good issue"])
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("design") }.fetchOne(db)
        }
        #expect(phase == nil)
        #expect(model.engine.errorText != nil)
        #expect(!model.engine.isRunning)
    }

    @Test
    func acceptAndWriteLeavesPriorIssuesIntactWhenCommitWroteNoIssues() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        try Self.seedIssue(database, id: UUID(-10), number: 1, title: "Good issue")
        try Self.seedSession(database, id: UUID(100))

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                // The commit Turn returns without writing any Issue.
                try await Self.resumeSession(for: request, turnID: UUID(201))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.acceptAndWrite()
        await model.runTask?.value

        // An empty write leaves the prior set intact and does not complete the Phase.
        let current = try await database.read { db in
            try WorkflowIssuesRequest(workflowID: UUID(-1)).fetch(db)
        }
        #expect(current.map(\.title) == ["Good issue"])
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("design") }.fetchOne(db)
        }
        #expect(phase == nil)
        #expect(!model.engine.isRunning)
    }

    // MARK: - Helpers

    @MainActor
    private static func makeModel(
        workflowDirectory: URL,
        database: any DatabaseWriter
    ) -> SmallJobModel {
        SmallJobModel(
            worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
            workflowDirectory: workflowDirectory, mcpServerCommand: mcpServerCommand, database: database
        )
    }

    /// Stands in for the live client's `send`, appending the resumed Turn.
    private static func resumeSession(for request: SendRequest, turnID: UUID) async throws -> Session {
        try await request.database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: turnID, sessionID: request.session.id.rawValue, userPrompt: request.prompt,
                    finalAnswer: "", createdAt: fixedDate.addingTimeInterval(1), updatedAt: fixedDate
                )
            }
            .execute(db)
        }
        return request.session
    }

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmallJobTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }

    private static func makeWorkflowDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SmallJobTests-WF-\(UUID().uuidString)", isDirectory: true)
    }

    private static func seedWorkflow(_ database: any DatabaseWriter) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(
                    id: UUID(-1), repoPath: "/repo", mode: WorkflowMode.small.rawValue,
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    /// The grill Session reuses the `.design` kind in Small Job mode.
    private static func seedSession(_ database: any DatabaseWriter, id: UUID) throws {
        try database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: id, workflowID: UUID(-1), worktreePath: "/repo", mode: "readOnly",
                    kind: "design", createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func seedIssue(
        _ database: any DatabaseWriter, id: UUID, number: Int, title: String
    ) throws {
        try database.write { db in
            try IssueRow.insert {
                IssueRow(
                    id: id, workflowID: UUID(-1), number: number, title: title,
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    /// Seeds `count` Issues (numbered 1…count) to stand in for the MCP child's out-of-process writes.
    private static func seedIssues(_ database: any DatabaseWriter, count: Int) async throws {
        try await database.write { db in
            for number in 1...count {
                try IssueRow.insert {
                    IssueRow(
                        id: UUID(1000 + number), workflowID: UUID(-1), number: number,
                        title: "Issue \(number)", createdAt: fixedDate, updatedAt: fixedDate
                    )
                }
                .execute(db)
            }
        }
    }
}
