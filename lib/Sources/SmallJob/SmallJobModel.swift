import Agent
import Chat
import Dependencies
import Foundation
import Skills
import Observation
import SQLiteData
import Store

/// Drives the Small Job mode's first Phase: a single grill-and-carve chat that occupies the Design
/// slot. The user grills freely (read-only, no writer), then commits the agreed Issues with one
/// button. Unlike Allocate there is no `propose()` step reading a PRD/summary — the grill *is* the
/// proposal conversation. `acceptAndWrite()` mirrors Allocate's transactional commit: snapshot the
/// prior ids, run the single writer Turn, then clear the snapshot and complete the `design` Phase only
/// if the write produced a new, non-empty set — so a failed or empty commit leaves the prior set
/// intact and doesn't falsely unlock Execute (its Artifact is rows, not a file).
@MainActor
@Observable
public final class SmallJobModel {
    public let engine: ChatEngine

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    @ObservationIgnored
    private let workflowDirectory: URL

    @ObservationIgnored
    private let skill: SkillResource

    @ObservationIgnored
    private let mcpServerCommand: String

    @ObservationIgnored
    @Fetch public var issues: [IssueRow] = []

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    /// - Parameter mcpServerCommand: the Hercules app binary, re-executed as the stdio create-issue MCP
    ///   server. The DB path and workflow id are fixed as launch args, so it can't target another Workflow's database.
    public init(
        worktree: URL,
        workflowID: UUID,
        workflowDirectory: URL,
        mcpServerCommand: String,
        database: any DatabaseWriter
    ) {
        self.workflowID = workflowID
        self.workflowDirectory = workflowDirectory
        self.database = database
        self.mcpServerCommand = mcpServerCommand
        self.skill = loadSkill(.smallJob)
        // Reuses the `.design` Session kind: a Small Job Workflow never has a standard Design Session, so
        // the slot is unambiguous. The grill-and-carve behaviour comes from the skill and the commit
        // Turn's writer, not the kind.
        self.engine = ChatEngine(
            worktree: worktree,
            mode: .readOnly,
            workflowID: workflowID,
            kind: .design,
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            database: database
        )
        _issues = Fetch(
            wrappedValue: [],
            WorkflowIssuesRequest(workflowID: workflowID),
            animation: .default
        )
    }

    public var isIntake: Bool { engine.isIntake }

    /// Whether this Phase's chat agent is mid-Turn — the Small Job contribution to the Workflow's
    /// aggregate running state. A thin reflection of the engine's run flag.
    public var isBusy: Bool { engine.isRunning }

    /// Cancels an in-flight chat Turn — the Small Job contribution to the Workflow-level stop-all. No-op
    /// when idle.
    public func cancel() {
        engine.cancel()
    }

    /// Available once a grill conversation exists — the commit Turn writes the agreed Issues.
    public var isAcceptAvailable: Bool { engine.session != nil && !engine.isRunning }

    /// Idempotent by construction: a full rewrite of the agreed set from scratch, one `create_issue` per
    /// Issue, even if Issues were created in an earlier Turn — so a re-commit doesn't no-op with "already
    /// created". The prior set is soft-deleted out-of-band once this write succeeds (see `acceptAndWrite`).
    static let commitPrompt = """
        Write the agreed set of Issues now from scratch: make exactly one create_issue call per Issue in \
        the set, even if you already created Issues in an earlier Turn. Recreate every Issue in the agreed \
        set — do not skip any as "already created".
        """

    /// The single path that commits Issues and completes the Small Job's first Phase, structured
    /// transactionally so a failed or empty commit can never zero out a previously-good set — identical to
    /// `AllocateModel.acceptAndWrite`, but it completes the `design` Phase (Small Job's first Phase) whose
    /// rows Artifact unlocks Execute.
    public func acceptAndWrite() {
        guard isAcceptAvailable else { return }
        engine.errorText = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                let priorIDs = Set(try currentIssues().map(\.id))
                try await engine.send(
                    Self.commitPrompt,
                    overrideMCPServers: [
                        Self.issueServer(
                            command: mcpServerCommand,
                            workflowDirectory: workflowDirectory,
                            workflowID: workflowID
                        )
                    ]
                )
                let newWrite = try currentIssues().filter { !priorIDs.contains($0.id) }
                if !newWrite.isEmpty {
                    try database.clearIssues(ids: priorIDs, workflowID: workflowID, now: now)
                    try database.completePhase(
                        workflowID: workflowID, kind: "design", id: uuid(), now: now
                    )
                }
            } catch {
                engine.errorText = error.localizedDescription
            }
            engine.isRunning = false
        }
    }

    private static func issueServer(
        command: String, workflowDirectory: URL, workflowID: UUID
    ) -> MCPServer {
        let databasePath = workflowDirectory.appendingPathComponent("workflow.sqlite").path
        return MCPServer(
            name: "hercules",
            command: command,
            args: [
                "--mcp-issue-server",
                "--db", databasePath,
                "--workflow-id", workflowID.uuidString,
            ],
            tools: ["create_issue"]
        )
    }

    /// Read directly so the completion gate keys on the rows the commit Turn just wrote rather than
    /// waiting for the `@Fetch` to refire.
    private func currentIssues() throws -> [IssueRow] {
        try database.read { db in
            try WorkflowIssuesRequest(workflowID: workflowID).fetch(db)
        }
    }
}
