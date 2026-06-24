import Agent
import Chat
import Dependencies
import Foundation
import Material
import Observation
import SQLiteData
import Store

/// Drives the Allocate Phase: a conversation with a button-gated commit. `propose()` reads the PRD and
/// Design summary and presents an Issue breakdown as text — writer-free, like every chat Turn. Only
/// `acceptAndWrite()` carries the create-issue writer (on its commit Turn), and it commits the agreed
/// set transactionally: snapshot the prior ids, write, then clear the snapshot and complete the Phase
/// only if the write produced a new, non-empty set — so a failed or empty commit leaves the prior set
/// intact and doesn't falsely unlock Execute (its Artifact is rows, not a file).
@MainActor
@Observable
public final class AllocateModel {
    let engine: ChatEngine

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
    @Fetch var issues: [IssueRow] = []

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
        self.skill = loadSkill(.toIssues)
        self.engine = ChatEngine(
            worktree: worktree,
            mode: .readOnly,
            workflowID: workflowID,
            kind: .allocate,
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

    /// Whether this Phase's chat agent is mid-Turn — the Allocate contribution to the Workflow's aggregate
    /// running state. A thin reflection of the engine's run flag.
    public var isBusy: Bool { engine.isRunning }

    public var isProposeAvailable: Bool { !engine.isRunning }

    /// Available only once a proposal conversation exists.
    public var isAcceptAvailable: Bool { engine.session != nil && !engine.isRunning }

    /// The heavy behavioural instructions — propose as text only, write nothing yet — live in the
    /// to-issues Skill.
    static func proposePrompt(prdPath: String, designPath: String) -> String {
        """
        Read the PRD at \(prdPath) and the Design summary at \(designPath), then propose the \
        breakdown into Issues as plain text. Do not write any Issues yet.
        """
    }

    /// Idempotent by construction: a full rewrite of the agreed set from scratch, one `create_issue` per
    /// Issue, even if Issues were created in an earlier Turn — so a re-commit doesn't no-op with "already
    /// created". The prior set is soft-deleted out-of-band once this write succeeds (see `acceptAndWrite`).
    static let commitPrompt = """
        Write the agreed set of Issues now from scratch: make exactly one create_issue call per Issue in \
        the set, even if you already created Issues in an earlier Turn. Recreate every Issue in the agreed \
        set — do not skip any as "already created".
        """

    /// Reads the PRD and Design summary locations from their completed Phase rows, attaches both, and
    /// sends the proposal prompt. Starts the Session the first time, resumes it on a re-propose.
    public func propose() {
        guard isProposeAvailable else { return }
        engine.errorText = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                let prd = try artifactURL(kind: "prd")
                let design = try artifactURL(kind: "design")
                try await engine.send(
                    Self.proposePrompt(prdPath: prd.path, designPath: design.path),
                    inputs: InputBundle(
                        root: workflowDirectory,
                        relativePaths: [relativePath(of: prd), relativePath(of: design)]
                    )
                )
            } catch {
                engine.errorText = error.localizedDescription
            }
            engine.isRunning = false
        }
    }

    /// The single path that commits Issues and completes the Allocate Phase, structured transactionally so
    /// a failed or empty commit can never zero out a previously-good set:
    ///
    /// 1. Snapshot the live Issue ids before sending the commit prompt.
    /// 2. Run the commit Turn — the only Turn that carries the create-issue writer, via the per-turn
    ///    `mcpServers` override.
    /// 3. The new write is the Issues whose ids aren't in the snapshot.
    /// 4. Only on a non-throwing return with a non-empty new write, soft-delete the snapshotted ids and
    ///    complete the Phase. `runTurn` throws on a failed/crashed Turn, so a broken commit lands in
    ///    `catch` before any delete/complete — the transactional ordering yields the completion gate for
    ///    free, and the old set stays fully intact.
    ///
    /// The brief window where old and new Issues coexist with duplicate numbers is harmless (plain index,
    /// no uniqueness constraint) and invisible mid-Turn.
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
                        workflowID: workflowID, kind: "allocate", id: uuid(), now: now
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

    /// A completed Phase's file Artifact, read from its `phase` row.
    private func artifactURL(kind: String) throws -> URL {
        let row = try database.read { db in
            try PhaseRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq(kind) }
                .where { $0.status.eq("complete") }
                .where { !$0.isDeleted }
                .fetchOne(db)
        }
        guard let path = row?.artifactPath else { throw AllocateError.artifactMissing(kind) }
        return URL(fileURLWithPath: path)
    }

    /// Read directly so the completion gate keys on the rows the commit Turn just wrote rather than
    /// waiting for the `@Fetch` to refire.
    private func currentIssues() throws -> [IssueRow] {
        try database.read { db in
            try WorkflowIssuesRequest(workflowID: workflowID).fetch(db)
        }
    }

    private func relativePath(of absolute: URL) -> String {
        let root = workflowDirectory.standardizedFileURL.path
        let path = absolute.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

enum AllocateError: LocalizedError {
    case artifactMissing(String)

    var errorDescription: String? {
        switch self {
        case .artifactMissing(let kind):
            "The completed \(kind) Phase's Artifact could not be found."
        }
    }
}
