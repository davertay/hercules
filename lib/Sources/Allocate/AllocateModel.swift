import Agent
import Chat
import Dependencies
import Foundation
import Material
import Observation
import SQLiteData
import Store

/// Drives the Allocate Phase: a hybrid of PRD's directed kickoff and Design's conversation, with a
/// button-gated commit. The shared `ChatEngine` is configured for a `readOnly` Session under the
/// bundled to-issues Skill with the repo as cwd (so the agent grounds Issue sizing in real code) and
/// the create-issue MCP server descriptor pinned on it. `propose()` runs a proposal Turn that reads
/// the PRD and Design summary and presents the breakdown as text — no Issues written. `acceptAndWrite()`
/// clears any prior Issues, runs the commit Turn that writes the agreed set via the MCP tool, then —
/// only if the write produced at least one Issue — marks the Allocate Phase complete (its Artifact is
/// rows, not a file, so the nil-path `completePhase` is used).
@MainActor
@Observable
public final class AllocateModel {
    /// The shared chat engine, configured for the Allocate Session. Driven by `propose()` /
    /// `acceptAndWrite()` and by the composer for refinement Turns; its streaming Transcript is the
    /// conversation display.
    let engine: ChatEngine

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    /// The Workflow's root directory (`~/.hercules/workflows/<id>/`); the PRD and Design Artifacts
    /// live beneath it and are attached as inputs by their relative `phases/...` paths.
    @ObservationIgnored
    private let workflowDirectory: URL

    @ObservationIgnored
    private let skill: SkillResource

    /// Live view of this Workflow's committed Issues, ordered by number. The Issue list and saved
    /// confirmation are derived from it, so they appear live when the commit Turn writes and survive
    /// closing and reopening the window.
    @ObservationIgnored
    @Fetch var issues: [IssueRow] = []

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    /// - Parameter mcpServerCommand: the path to the Hercules app binary, re-executed as the stdio
    ///   create-issue MCP server. The DB path and workflow id are fixed as launch arguments here, so
    ///   the model can never target another Workflow's database.
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
        self.skill = loadSkill(.toIssues)
        self.engine = ChatEngine(
            worktree: worktree,
            mode: .readOnly,
            workflowID: workflowID,
            kind: .allocate,
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            mcpServers: [Self.issueServer(command: mcpServerCommand, workflowDirectory: workflowDirectory, workflowID: workflowID)],
            database: database
        )
        _issues = Fetch(
            wrappedValue: [],
            WorkflowIssuesRequest(workflowID: workflowID),
            animation: .default
        )
    }

    /// True before any conversation exists — drives the intake action instead of the transcript.
    public var isIntake: Bool { engine.isIntake }

    /// Whether the Propose action can run: not while a Turn is in flight.
    public var isProposeAvailable: Bool { !engine.isRunning }

    /// Whether the Accept & Write action can run: only once a proposal conversation exists, and not
    /// while a Turn is in flight.
    public var isAcceptAvailable: Bool { engine.session != nil && !engine.isRunning }

    /// The directed instruction the proposal Turn runs with; the heavy behavioural instructions —
    /// propose as text only, write nothing yet — live in the to-issues Skill.
    static func proposePrompt(prdPath: String, designPath: String) -> String {
        """
        Read the PRD at \(prdPath) and the Design summary at \(designPath), then propose the \
        breakdown into Issues as plain text. Do not write any Issues yet.
        """
    }

    /// The directed instruction the commit Turn resumes the Session with; the Skill carries the rule
    /// that this is the only point at which `create_issue` is called.
    static let commitPrompt =
        "Write the agreed set of Issues now, one create_issue call per Issue."

    /// Runs the proposal Turn: reads the PRD and Design summary locations from their completed Phase
    /// rows (the single source of truth), attaches both as one `InputBundle` rooted at the Workflow
    /// directory, and sends the directed proposal prompt. `ChatEngine.send` starts the Session the
    /// first time and resumes it on a re-propose. No Issues are written.
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

    /// Commits the agreed breakdown: clears any previously written Allocate Issues so a re-commit
    /// replaces the set cleanly, resumes the Session with the commit instruction (the agent writes
    /// each Issue via the create-issue MCP tool), then re-reads the Issues. Only if the write produced
    /// at least one Issue is the Allocate Phase marked complete (nil Artifact path), so a commit Turn
    /// that wrote nothing does not falsely unlock Execute.
    public func acceptAndWrite() {
        guard isAcceptAvailable else { return }
        engine.errorText = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                try database.clearIssues(workflowID: workflowID, now: now)
                try await engine.send(Self.commitPrompt)
                let written = try currentIssues()
                if !written.isEmpty {
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

    /// The create-issue MCP server descriptor: the app binary re-executed with the stdio subcommand,
    /// with the Workflow DB path and id fixed as launch arguments.
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

    /// The location of a completed Phase's file Artifact, read from its `phase` row (single source of
    /// truth) — the PRD at `phases/prd/prd.md`, the Design summary at `phases/design/summary.md`.
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

    /// The Workflow's current non-deleted Issues, read directly so the completion gate keys on the
    /// rows the commit Turn actually wrote rather than waiting for the `@Fetch` to refire.
    private func currentIssues() throws -> [IssueRow] {
        try database.read { db in
            try WorkflowIssuesRequest(workflowID: workflowID).fetch(db)
        }
    }

    /// `absolute`'s path relative to the Workflow directory, so the two Artifacts are listed as the
    /// `phases/...` paths under the bundle root rather than absolute paths.
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
