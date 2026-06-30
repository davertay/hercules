import Agent
import Chat
import Dependencies
import Foundation
import Skills
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

    public var isBusy: Bool { engine.isRunning }

    public func cancel() {
        engine.cancel()
    }

    public var isProposeAvailable: Bool { !engine.isRunning }

    public var isAcceptAvailable: Bool { engine.session != nil && !engine.isRunning }

    static func proposePrompt(prdPath: String?, designPath: String) -> String {
        if let prdPath {
            """
            Read the PRD at \(prdPath) and the Design summary at \(designPath), then propose the \
            breakdown into Issues as plain text. Do not write any Issues yet.
            """
        } else {
            """
            Read the Design summary at \(designPath) — no PRD was produced for this Workflow — then \
            propose the breakdown into Issues as plain text. Do not write any Issues yet.
            """
        }
    }

    static let commitPrompt = """
        Write the agreed set of Issues now from scratch: make exactly one create_issue call per Issue in \
        the set, even if you already created Issues in an earlier Turn. Recreate every Issue in the agreed \
        set — do not skip any as "already created".
        """

    public func propose() {
        guard isProposeAvailable else { return }
        engine.errorText = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                let design = try artifactURL(kind: "design")
                let prd = optionalArtifactURL(kind: "prd")
                let relativePaths = [prd, design]
                    .compactMap { $0 }
                    .map { workflowRelativePath(of: $0.path, under: workflowDirectory) }
                try await engine.send(
                    Self.proposePrompt(prdPath: prd?.path, designPath: design.path),
                    inputs: InputBundle(root: workflowDirectory, relativePaths: relativePaths)
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

    private func artifactURL(kind: String) throws -> URL {
        guard let path = try database.completedArtifactPath(workflowID: workflowID, kind: kind) else {
            throw AllocateError.artifactMissing(kind)
        }
        return URL(fileURLWithPath: path)
    }

    private func optionalArtifactURL(kind: String) -> URL? {
        (try? database.completedArtifactPath(workflowID: workflowID, kind: kind))
            .flatMap { $0 }
            .map { URL(fileURLWithPath: $0) }
    }

    private func currentIssues() throws -> [IssueRow] {
        try database.read { db in
            try WorkflowIssuesRequest(workflowID: workflowID).fetch(db)
        }
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
