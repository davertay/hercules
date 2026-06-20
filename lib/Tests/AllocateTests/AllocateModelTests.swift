import Agent
import Dependencies
import Foundation
import Material
import SQLiteData
import Store
import Testing

@testable import Allocate

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
private let mcpServerCommand = "/repo/.build/hercules"

@MainActor
@Suite("AllocateModel")
struct AllocateModelTests {

    // MARK: - Material wiring

    @Test
    func toIssuesSkillResolvesFromBundle() {
        let skill = loadSkill(.toIssues)
        #expect(skill.name == "to-issues")
        #expect(skill.fileUrl.path.hasSuffix("skills/to-issues/SKILL.md"))
        #expect(skill.folderUrl == skill.fileUrl.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: skill.fileUrl.path))
    }

    // MARK: - propose

    @Test
    func proposeRunsOneReadOnlyAllocateTurnWithBothArtifactsSkillAndMCPServer() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let prdPath = Self.artifactPath(workflowDirectory, "phases/prd/prd.md")
        let designPath = Self.artifactPath(workflowDirectory, "phases/design/summary.md")
        try Self.seedWorkflow(database)
        try Self.seedCompletedPhase(database, kind: "prd", artifactPath: prdPath, id: UUID(-2))
        try Self.seedCompletedPhase(database, kind: "design", artifactPath: designPath, id: UUID(-3))
        let skill = loadSkill(.toIssues)
        let captured = LockIsolated<StartRequest?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                captured.setValue(request)
                return try await Self.startSession(for: request, id: UUID(100))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.propose()
        await model.runTask?.value

        let request = try #require(captured.value)
        #expect(request.mode == .readOnly)
        #expect(request.worktree == URL(fileURLWithPath: "/repo"))
        #expect(request.workflowID == UUID(-1))
        #expect(request.kind == .allocate)
        #expect(request.skillFiles == [skill.fileUrl])
        #expect(request.addDirs == [skill.folderUrl])
        #expect(request.prompt == AllocateModel.proposePrompt(prdPath: prdPath, designPath: designPath))
        // Both Artifacts are attached as one bundle rooted at the Workflow directory, listed by their
        // relative `phases/...` paths.
        let inputs = try #require(request.inputs)
        #expect(inputs.root == workflowDirectory)
        #expect(inputs.relativePaths == ["phases/prd/prd.md", "phases/design/summary.md"])
        // The create-issue MCP server descriptor carries the DB path + workflow id as launch arguments.
        let databasePath = workflowDirectory.appendingPathComponent("workflow.sqlite").path
        #expect(request.mcpServers == [
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
        #expect(model.engine.errorText == nil)
        #expect(!model.engine.isRunning)
    }

    @Test
    func proposeWritesNoIssues() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        try Self.seedCompletedPhase(
            database, kind: "prd", artifactPath: Self.artifactPath(workflowDirectory, "phases/prd/prd.md"), id: UUID(-2)
        )
        try Self.seedCompletedPhase(
            database, kind: "design",
            artifactPath: Self.artifactPath(workflowDirectory, "phases/design/summary.md"), id: UUID(-3)
        )

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.start = { @Sendable request in
                try await Self.startSession(for: request, id: UUID(100))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.propose()
        await model.runTask?.value

        let issues = try await database.read { db in try IssueRow.fetchAll(db) }
        #expect(issues.isEmpty)
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
        }
        #expect(phase == nil)
    }

    // MARK: - acceptAndWrite

    @Test
    func acceptAndWriteClearsPriorIssuesBeforeCommitAndCompletesPhaseWhenIssuesExist() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        // A prior committed Issue and an existing Allocate Session, as found when reopening the window
        // after a previous propose/accept.
        try Self.seedIssue(database, id: UUID(-10), number: 1, title: "Stale issue")
        try Self.seedSession(database, id: UUID(100))
        let clearedAt = LockIsolated<Bool?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                // At the commit Turn the prior Issue must already be cleared; the MCP child's writes
                // are stood in for by seeding fresh Issue rows here.
                let priorDeleted = try await request.database.read { db in
                    try IssueRow.find(UUID(-10)).fetchOne(db)?.isDeleted ?? false
                }
                clearedAt.setValue(priorDeleted)
                try await Self.seedIssues(request.database, count: 2)
                return try await Self.resumeSession(for: request, turnID: UUID(201))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        #expect(model.isAcceptAvailable)
        model.acceptAndWrite()
        await model.runTask?.value

        // clearIssues ran before the commit Turn.
        #expect(clearedAt.value == true)
        // The stale Issue is soft-deleted; the freshly written set is current.
        let current = try await database.read { db in
            try WorkflowIssuesRequest(workflowID: UUID(-1)).fetch(db)
        }
        #expect(current.map(\.number) == [1, 2])
        // The Allocate Phase is complete with a null Artifact path.
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
        }
        #expect(phase?.status == "complete")
        #expect(phase?.artifactPath == nil)
        #expect(model.engine.errorText == nil)
        #expect(!model.engine.isRunning)
    }

    @Test
    func acceptAndWriteDoesNotCompletePhaseWhenCommitWroteNoIssues() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        try Self.seedSession(database, id: UUID(100))

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                // The commit Turn writes nothing.
                try await Self.resumeSession(for: request, turnID: UUID(201))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.acceptAndWrite()
        await model.runTask?.value

        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
        }
        #expect(phase == nil)
        #expect(!model.engine.isRunning)
    }

    // MARK: - Helpers

    @MainActor
    private static func makeModel(
        workflowDirectory: URL,
        database: any DatabaseWriter
    ) -> AllocateModel {
        AllocateModel(
            worktree: URL(fileURLWithPath: "/repo"), workflowID: UUID(-1),
            workflowDirectory: workflowDirectory, mcpServerCommand: mcpServerCommand, database: database
        )
    }

    /// Stands in for the live client's `start`: records the Session and its one Turn, then returns the
    /// started Session pinned with the request's skill/dir/MCP state.
    private static func startSession(for request: StartRequest, id: UUID) async throws -> Session {
        try await request.database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: id, workflowID: request.workflowID, worktreePath: request.worktree.path,
                    mode: request.mode.rawValue, kind: request.kind.rawValue,
                    createdAt: fixedDate, updatedAt: fixedDate
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

    /// Stands in for the live client's `send`: appends the resumed Turn and returns the same Session.
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
            .appendingPathComponent("AllocateTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }

    private static func makeWorkflowDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AllocateTests-WF-\(UUID().uuidString)", isDirectory: true)
    }

    private static func artifactPath(_ workflowDirectory: URL, _ relative: String) -> String {
        workflowDirectory.appendingPathComponent(relative).path
    }

    private static func seedWorkflow(_ database: any DatabaseWriter) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: UUID(-1), repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
        }
    }

    private static func seedCompletedPhase(
        _ database: any DatabaseWriter, kind: String, artifactPath: String, id: UUID
    ) throws {
        try database.write { db in
            try PhaseRow.insert {
                PhaseRow(
                    id: id, workflowID: UUID(-1), kind: kind, status: "complete",
                    artifactPath: artifactPath, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func seedSession(_ database: any DatabaseWriter, id: UUID) throws {
        try database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: id, workflowID: UUID(-1), worktreePath: "/repo", mode: "readOnly",
                    kind: "allocate", createdAt: fixedDate, updatedAt: fixedDate
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
