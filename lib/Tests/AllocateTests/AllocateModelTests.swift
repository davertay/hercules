import Agent
import Dependencies
import Foundation
import Skills
import SQLiteData
import Store
import Testing

@testable import Allocate
@testable import Chat

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

    @Test
    func toPrdSkillResolvesFromBundle() {
        let skill = loadSkill(.toPrd)
        #expect(skill.name == "to-prd")
        #expect(skill.fileUrl.path.hasSuffix("skills/to-prd/SKILL.md"))
        #expect(skill.folderUrl == skill.fileUrl.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: skill.fileUrl.path))
    }

    // MARK: - propose

    @Test
    func proposeRunsOneReadOnlyAllocateTurnWithBothArtifactsAndSkillButNoWriter() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let prdPath = AllocateModel.prdURL(in: workflowDirectory).path
        let designPath = Self.artifactPath(workflowDirectory, "phases/design/summary.md")
        try Self.seedWorkflow(database)
        // The PRD is a hidden file the PRD Turn writes, not a Phase — present it at its fixed path.
        try Self.writePRDFile(workflowDirectory)
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
        // Both Artifacts attached as one bundle, listed by relative `phases/...` paths.
        let inputs = try #require(request.inputs)
        #expect(inputs.root == workflowDirectory)
        #expect(inputs.relativePaths == ["phases/prd/prd.md", "phases/design/summary.md"])
        // The propose/chat Turn is writer-free: the create-issue server is attached only on the
        // acceptAndWrite() commit Turn.
        #expect(request.mcpServers.isEmpty)
        #expect(model.engine.errorText == nil)
        #expect(!model.engine.isRunning)
    }

    @Test
    func proposeAttachesTheDesignSummaryAloneWhenNoPRDWasWritten() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let designPath = Self.artifactPath(workflowDirectory, "phases/design/summary.md")
        try Self.seedWorkflow(database)
        // No PRD file was written (e.g. propose called before any PRD Turn) — only the summary is fed.
        try Self.seedCompletedPhase(database, kind: "design", artifactPath: designPath, id: UUID(-3))
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
        // The PRD-less prompt is used, and only the Design summary is attached.
        #expect(request.prompt == AllocateModel.proposePrompt(prdPath: nil, designPath: designPath))
        let inputs = try #require(request.inputs)
        #expect(inputs.root == workflowDirectory)
        #expect(inputs.relativePaths == ["phases/design/summary.md"])
        #expect(model.engine.errorText == nil)
        #expect(!model.engine.isRunning)
    }

    @Test
    func proposeWritesNoIssues() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        try Self.writePRDFile(workflowDirectory)
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

    // MARK: - Big path (PRD checkpoint → fresh carve)

    @Test
    func bridgeAndProposeRunsPRDTurnThenAutoProposesWithoutCommitting() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let designPath = Self.artifactPath(workflowDirectory, "phases/design/summary.md")
        let prdURL = AllocateModel.prdURL(in: workflowDirectory)
        try Self.seedWorkflow(database)
        // The live grill sits in the `.design` slot for the PRD Turn to resume; the completed Design Phase
        // supplies the summary the auto-propose reads.
        try Self.seedDesignSession(database, id: UUID(100))
        try Self.seedCompletedPhase(database, kind: "design", artifactPath: designPath, id: UUID(-3))
        let toIssues = loadSkill(.toIssues)
        let toPrd = loadSkill(.toPrd)
        let prdTurn = LockIsolated<SendRequest?>(nil)
        let proposeTurn = LockIsolated<StartRequest?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                // The PRD Turn resumes the `.design` grill; stub the write_artifact child by leaving a
                // non-empty prd.md so the completion gate passes and the auto-propose finds the bridge.
                prdTurn.setValue(request)
                try Self.writePRDFile(workflowDirectory)
                return try await Self.resumeSession(for: request, turnID: UUID(201))
            }
            $0.agentClient.start = { @Sendable request in
                proposeTurn.setValue(request)
                return try await Self.startSession(for: request, id: UUID(101))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        #expect(model.isBridgeAvailable)
        model.bridgeAndPropose()
        await model.runTask?.value

        // Step 1 — the PRD Turn resumes the `.design` Session under the to-prd Skill with a write_artifact
        // override targeting prd.md, no documents fed (the grill is the context).
        let prd = try #require(prdTurn.value)
        #expect(prd.session.id.rawValue == UUID(100))
        #expect(prd.session.kind == .design)
        #expect(prd.session.skillFiles == [toPrd.fileUrl])
        #expect(prd.prompt == AllocateModel.prdPrompt)
        #expect(prd.inputs == nil)
        #expect(prd.mcpServers == [Self.artifactServer(command: mcpServerCommand, artifactURL: prdURL)])

        // Step 2 — the auto-propose is a fresh `.allocate` Session under the to-issues Skill reading
        // prd.md + summary.md as an input bundle, writer-free.
        let propose = try #require(proposeTurn.value)
        #expect(propose.kind == .allocate)
        #expect(propose.skillFiles == [toIssues.fileUrl])
        #expect(propose.prompt == AllocateModel.proposePrompt(prdPath: prdURL.path, designPath: designPath))
        let inputs = try #require(propose.inputs)
        #expect(inputs.root == workflowDirectory)
        #expect(inputs.relativePaths == ["phases/prd/prd.md", "phases/design/summary.md"])
        #expect(propose.mcpServers.isEmpty)

        // No commit: no Issues written and the allocate Phase is not completed.
        let issues = try await database.read { db in try IssueRow.fetchAll(db) }
        #expect(issues.isEmpty)
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
        }
        #expect(phase == nil)
        #expect(model.engine.errorText == nil)
        #expect(!model.isBusy)
    }

    @Test
    func bridgeAndProposeSurfacesErrorAndSkipsProposeWhenPRDTurnWritesNothing() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        try Self.seedDesignSession(database, id: UUID(100))
        try Self.seedCompletedPhase(
            database, kind: "design",
            artifactPath: Self.artifactPath(workflowDirectory, "phases/design/summary.md"), id: UUID(-3)
        )
        // A prior committed Issue that a failed bridge must leave untouched.
        try Self.seedIssue(database, id: UUID(-10), number: 1, title: "Good issue")
        let proposeStarted = LockIsolated(false)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                // The PRD Turn returns without ever calling write_artifact — no prd.md appears.
                try await Self.resumeSession(for: request, turnID: UUID(201))
            }
            $0.agentClient.start = { @Sendable request in
                proposeStarted.setValue(true)
                return try await Self.startSession(for: request, id: UUID(101))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.bridgeAndPropose()
        await model.runTask?.value

        // The unwritten PRD short-circuits before the auto-propose, and the error is surfaced.
        #expect(!proposeStarted.value)
        #expect(model.engine.errorText != nil)
        #expect(model.prdSavedURL == nil)
        // The prior Issue set and Phase state are fully intact.
        let current = try await database.read { db in
            try WorkflowIssuesRequest(workflowID: UUID(-1)).fetch(db)
        }
        #expect(current.map(\.title) == ["Good issue"])
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
        }
        #expect(phase == nil)
        #expect(!model.isBusy)
    }

    @Test
    func regeneratePRDResumesDesignWithToPrdSkillAndWriteArtifactOverrideThenReProposes() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let prdURL = AllocateModel.prdURL(in: workflowDirectory)
        try Self.seedWorkflow(database)
        try Self.seedDesignSession(database, id: UUID(100))
        try Self.seedCompletedPhase(
            database, kind: "design",
            artifactPath: Self.artifactPath(workflowDirectory, "phases/design/summary.md"), id: UUID(-3)
        )
        // A PRD already exists (an earlier bridge), so Regenerate is available; its old modification time
        // lets the gate see the rewrite advance.
        try Self.writePRDFile(workflowDirectory, modified: fixedDate)
        let prdTurn = LockIsolated<SendRequest?>(nil)
        let reProposed = LockIsolated(false)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                prdTurn.setValue(request)
                // The regenerated write advances the file's modification time past the old snapshot.
                try Self.writePRDFile(workflowDirectory)
                return try await Self.resumeSession(for: request, turnID: UUID(201))
            }
            $0.agentClient.start = { @Sendable request in
                reProposed.setValue(true)
                return try await Self.startSession(for: request, id: UUID(101))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        #expect(model.isRegeneratePRDAvailable)
        model.regeneratePRD()
        await model.runTask?.value

        // The regenerate PRD Turn resumes `.design` under to-prd with the regenerate prompt and the same
        // write_artifact override, then the auto-propose follows.
        let prd = try #require(prdTurn.value)
        #expect(prd.session.kind == .design)
        #expect(prd.session.skillFiles == [loadSkill(.toPrd).fileUrl])
        #expect(prd.prompt == AllocateModel.regeneratePRDPrompt)
        #expect(prd.mcpServers == [Self.artifactServer(command: mcpServerCommand, artifactURL: prdURL)])
        #expect(reProposed.value)
        #expect(model.engine.errorText == nil)
        #expect(!model.isBusy)
    }

    @Test
    func prdSavedURLReflectsTheWrittenBridgeFile() throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        // No bridge yet — the View PRD disclosure has nothing to open.
        #expect(model.prdSavedURL == nil)

        // Once the PRD Turn has written the file, the disclosure resolves to it.
        try Self.writePRDFile(workflowDirectory)
        #expect(model.prdSavedURL == AllocateModel.prdURL(in: workflowDirectory))
    }

    // MARK: - acceptAndWrite

    @Test
    func acceptAndWriteAttachesWriterClearsPriorIssuesAfterSuccessAndCompletesPhase() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        // A prior committed Issue and Allocate Session, as found when reopening after a propose/accept.
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
        // The Phase is complete with a null Artifact path.
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
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
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
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
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
        }
        #expect(phase == nil)
        #expect(!model.engine.isRunning)
    }

    // MARK: - The small/big fork

    @Test
    func forkDefaultsToBigAndCanBeReChosen() throws {
        let database = try Self.makeDatabase()
        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            Self.makeModel(workflowDirectory: Self.makeWorkflowDirectory(), database: database)
        }

        // A plain static default for now; the recommendation that pre-selects it lands in a later slice.
        #expect(model.fork == .big)
        #expect(model.activeEngine === model.engine)

        // Re-opening Allocate lets the user re-choose the fork (small ↔ big).
        model.fork = .small
        #expect(model.activeEngine === model.smallEngine)
        model.fork = .big
        #expect(model.activeEngine === model.engine)
    }

    // MARK: - Small path (live carve)

    @Test
    func carveResumesTheDesignSessionWithToIssuesSkillAndNoInputDocuments() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        // A live grill Session sits in the `.design` slot for the small path to resume.
        try Self.seedDesignSession(database, id: UUID(100))
        let skill = loadSkill(.toIssues)
        let captured = LockIsolated<SendRequest?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                captured.setValue(request)
                return try await Self.resumeSession(for: request, turnID: UUID(201))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.fork = .small
        #expect(model.isCarveAvailable)
        model.carve()
        await model.runTask?.value

        let request = try #require(captured.value)
        // A resume (send, not start) of the existing `.design` Session under the to-issues Skill…
        #expect(request.session.id.rawValue == UUID(100))
        #expect(request.session.kind == .design)
        #expect(request.session.skillFiles == [skill.fileUrl])
        // …with no PRD/Design documents attached — the live grill *is* the context…
        #expect(request.inputs == nil)
        // …and writer-free: only acceptAndWrite() carries the create-issue server.
        #expect(request.mcpServers == nil)
        #expect(request.prompt == AllocateModel.carvePrompt)
        #expect(model.smallEngine.errorText == nil)
        #expect(!model.smallEngine.isRunning)
    }

    @Test
    func carveMessagesHideTheGrillTurnsBeforeTheCutoverBoundary() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        try Self.seedDesignSession(database, id: UUID(100))
        let boundary = fixedDate.addingTimeInterval(10)
        try await database.write { db in
            // A grill Turn before the boundary; the finalization completed `design` at `boundary`; then a
            // carve Turn after it — all in the shared `.design` Session.
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-30), sessionID: UUID(100), userPrompt: "grill turn",
                    createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
            try PhaseRow.insert {
                PhaseRow(
                    id: UUID(-2), workflowID: UUID(-1), kind: "design", status: "complete",
                    artifactPath: "/wf/phases/design/summary.md", createdAt: fixedDate, updatedAt: boundary
                )
            }
            .execute(db)
            try TurnRow.insert {
                TurnRow(
                    id: UUID(-40), sessionID: UUID(100), userPrompt: "carve turn",
                    createdAt: boundary.addingTimeInterval(1), updatedAt: fixedDate
                )
            }
            .execute(db)
        }

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }
        try await model.$designPhase.load()
        try await model.smallEngine.$conversation.load()

        // The boundary is the completed `design` Phase's completion instant.
        #expect(model.cutoverBoundary == boundary)
        // The grill Turn is hidden; only the carve Turn shows, so Allocate reads as a clean new Phase.
        #expect(model.carveMessages.map(\.text) == ["carve turn"])
    }

    @Test
    func acceptAndWriteOnSmallPathCommitsOnTheDesignSessionAndCompletesAllocate() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        // A prior committed Issue plus the live grill `.design` Session the small path resumes.
        try Self.seedIssue(database, id: UUID(-10), number: 1, title: "Stale issue")
        try Self.seedDesignSession(database, id: UUID(100))
        let committedKind = LockIsolated<SessionKind?>(nil)
        let committedServers = LockIsolated<[MCPServer]?>(nil)

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                committedKind.setValue(request.session.kind)
                committedServers.setValue(request.mcpServers)
                try await Self.seedIssues(request.database, count: 2)
                return try await Self.resumeSession(for: request, turnID: UUID(201))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.fork = .small
        #expect(model.isAcceptAvailable)
        model.acceptAndWrite()
        await model.runTask?.value

        // The commit resumed the `.design` Session yet completes the `allocate` Phase — SessionKind and
        // Phase are independent.
        #expect(committedKind.value == .design)
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
        // Transactional: the prior Issue is soft-deleted only after the write succeeded.
        let prior = try await database.read { db in try IssueRow.find(UUID(-10)).fetchOne(db) }
        #expect(prior?.isDeleted == true)
        let current = try await database.read { db in
            try WorkflowIssuesRequest(workflowID: UUID(-1)).fetch(db)
        }
        #expect(current.map(\.number) == [1, 2])
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
        }
        #expect(phase?.status == "complete")
        #expect(model.smallEngine.errorText == nil)
        #expect(!model.smallEngine.isRunning)
    }

    @Test
    func acceptAndWriteOnSmallPathLeavesPriorIssuesIntactWhenCommitWroteNoIssues() async throws {
        let database = try Self.makeDatabase()
        let workflowDirectory = Self.makeWorkflowDirectory()
        try Self.seedWorkflow(database)
        try Self.seedIssue(database, id: UUID(-10), number: 1, title: "Good issue")
        try Self.seedDesignSession(database, id: UUID(100))

        let model = withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date.now = fixedDate
            $0.agentClient.send = { @Sendable request in
                // The carve commit Turn returns without writing any Issue.
                try await Self.resumeSession(for: request, turnID: UUID(201))
            }
        } operation: {
            Self.makeModel(workflowDirectory: workflowDirectory, database: database)
        }

        model.fork = .small
        model.acceptAndWrite()
        await model.runTask?.value

        // An empty write leaves the prior set intact and does not complete the Phase.
        let current = try await database.read { db in
            try WorkflowIssuesRequest(workflowID: UUID(-1)).fetch(db)
        }
        #expect(current.map(\.title) == ["Good issue"])
        let phase = try await database.read { db in
            try PhaseRow.where { $0.kind.eq("allocate") }.fetchOne(db)
        }
        #expect(phase == nil)
        #expect(!model.smallEngine.isRunning)
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

    /// Stands in for the live client's `start`, recording the Session and its one Turn.
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

    /// Writes a non-empty `prd.md` at the fixed bridge path, standing in for the PRD Turn's write_artifact
    /// child. `modified` back-dates it so a subsequent rewrite's advanced modification time is observable.
    /// `nonisolated` so the off-main-actor `agentClient` stubs can call it while faking the child's write.
    nonisolated private static func writePRDFile(_ workflowDirectory: URL, modified: Date? = nil) throws {
        let url = AllocateModel.prdURL(in: workflowDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "# PRD\n\nThe distilled requirements.".write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    /// The write_artifact MCP server the PRD Turn is expected to carry, pointed at `prd.md`.
    private static func artifactServer(command: String, artifactURL: URL) -> MCPServer {
        MCPServer(
            name: "hercules",
            command: command,
            args: ["--mcp-artifact-server", "--artifact-path", artifactURL.path],
            tools: ["write_artifact"]
        )
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

    /// The live grill `.design` Session the small path rediscovers and resumes.
    private static func seedDesignSession(_ database: any DatabaseWriter, id: UUID) throws {
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
