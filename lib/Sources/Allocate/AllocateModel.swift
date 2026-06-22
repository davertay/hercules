import Agent
import Chat
import Dependencies
import Foundation
import Material
import Observation
import SQLiteData
import Store

/// Drives the Allocate Phase: a conversation with a button-gated commit. `propose()` reads the PRD and
/// Design summary and presents an Issue breakdown as text; `acceptAndWrite()` clears any prior Issues,
/// runs the commit Turn that writes the agreed set via the create-issue MCP tool, then marks the Phase
/// complete only if the write produced at least one Issue (its Artifact is rows, not a file).
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

    /// The PRD and Design Artifacts live beneath this and are attached by their relative `phases/...`
    /// paths.
    @ObservationIgnored
    private let workflowDirectory: URL

    @ObservationIgnored
    private let skill: SkillResource

    @ObservationIgnored
    @Fetch var issues: [IssueRow] = []

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    /// - Parameter mcpServerCommand: the Hercules app binary, re-executed as the stdio create-issue MCP
    ///   server. The DB path and workflow id are fixed as launch args, so it can't target another
    ///   Workflow's database.
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

    public var isIntake: Bool { engine.isIntake }

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

    static let commitPrompt =
        "Write the agreed set of Issues now, one create_issue call per Issue."

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

    /// Clears any prior Issues so a re-commit replaces the set cleanly, then writes via the MCP tool.
    /// Completes the Phase only if the write produced at least one Issue, so an empty commit doesn't
    /// falsely unlock Execute.
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
