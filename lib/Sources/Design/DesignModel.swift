import Agent
import Chat
import Dependencies
import Foundation
import Skills
import Observation
import SQLiteData
import Store

/// Drives the Design Phase: a `ChatEngine` conversation plus orchestration to generate the summary
/// Artifact and record the Phase complete.
@MainActor
@Observable
public final class DesignModel {
    let engine: ChatEngine

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    /// The Design summary Artifact is written beneath this at `phases/design/summary.md`.
    @ObservationIgnored
    private let workflowDirectory: URL

    /// The Hercules app binary, re-executed as the stdio `write_artifact` MCP server (ADR 0006).
    @ObservationIgnored
    private let mcpServerCommand: String

    @ObservationIgnored
    private let skill: SkillResource

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    @ObservationIgnored
    @Fetch var designPhase: PhaseRow?

    private var summaryDismissed = false

    public var summarySavedURL: URL? {
        guard !summaryDismissed else { return nil }
        return designPhase?.artifactPath.map { URL(fileURLWithPath: $0) }
    }

    public init(
        worktree: URL,
        workflowID: UUID,
        workflowDirectory: URL,
        mcpServerCommand: String,
        database: any DatabaseWriter
    ) {
        self.workflowID = workflowID
        self.workflowDirectory = workflowDirectory
        self.mcpServerCommand = mcpServerCommand
        self.database = database
        self.skill = loadSkill(.grillMe)
        self.engine = ChatEngine(
            worktree: worktree,
            mode: .readOnly,
            workflowID: workflowID,
            kind: .design,
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            database: database
        )
        _designPhase = Fetch(
            wrappedValue: nil,
            CompletedDesignPhaseRequest(workflowID: workflowID),
            animation: .default
        )
        // Dismiss the saved-summary confirmation the moment the user sends a new message.
        engine.onSend = { [weak self] in self?.summaryDismissed = true }
    }

    public var isIntake: Bool { engine.isIntake }

    /// Whether this Phase's chat agent is mid-Turn — the Design contribution to the Workflow's aggregate
    /// running state. A thin reflection of the engine's run flag.
    public var isBusy: Bool { engine.isRunning }

    /// Cancels an in-flight chat Turn — the Design contribution to the Workflow-level stop-all. No-op
    /// when idle.
    public func cancel() {
        engine.cancel()
    }

    public var isGenerateSummaryAvailable: Bool {
        engine.session != nil
    }

    static let finalizationPrompt = """
        Produce the complete design summary now and save it by calling the write_artifact tool with the \
        full markdown document.
        """

    /// Runs the finalization Turn and completes the Phase only on a verified `write_artifact` write.
    ///
    /// The writer is attached as a per-Turn `mcpServers` override, not pinned on the Session: this Turn is
    /// always a resume (a Design Session already exists from grilling), so the override applies, and
    /// pinning it would instead arm every grill Turn — violating the "only the commit Turn can write"
    /// guarantee. The completion gate is transactional like Allocate's: snapshot the destination file
    /// first, run the Turn, and complete only if it now exists, is non-empty, and (re-running over an
    /// existing file) its modification time advanced. A Turn that never called the tool leaves the file
    /// untouched and surfaces an error instead of falsely completing.
    public func generateSummary() {
        guard engine.session != nil, !engine.isRunning else { return }
        engine.errorText = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                let url = summaryURL()
                let before = artifactSnapshot(at: url)
                try await engine.send(
                    Self.finalizationPrompt,
                    overrideMCPServers: [Self.artifactServer(command: mcpServerCommand, artifactURL: url)]
                )
                guard artifactWasWritten(at: url, since: before) else {
                    throw DesignError.summaryNotWritten
                }
                try database.completePhase(
                    workflowID: workflowID, kind: "design", artifactPath: url.path,
                    id: uuid(), now: now
                )
                // Reveal the banner again; `summarySavedURL` now reads the freshly persisted row.
                summaryDismissed = false
            } catch {
                engine.errorText = error.localizedDescription
            }
            engine.isRunning = false
        }
    }

    private func summaryURL() -> URL {
        workflowDirectory
            .appending(path: "phases/design", directoryHint: .isDirectory)
            .appending(path: "summary.md")
    }

    private static func artifactServer(command: String, artifactURL: URL) -> MCPServer {
        MCPServer(
            name: "hercules",
            command: command,
            args: ["--mcp-artifact-server", "--artifact-path", artifactURL.path],
            tools: ["write_artifact"]
        )
    }
}

enum DesignError: LocalizedError {
    case summaryNotWritten

    var errorDescription: String? {
        switch self {
        case .summaryNotWritten:
            "The design summary was not saved — the agent must call write_artifact to write it."
        }
    }
}

struct CompletedDesignPhaseRequest: FetchKeyRequest {
    var workflowID: UUID = UUID()

    func fetch(_ db: Database) throws -> PhaseRow? {
        try completedPhaseRow(db, workflowID: workflowID, kind: "design")
    }
}
