import Agent
import Chat
import Dependencies
import Foundation
import Skills
import Observation
import SQLiteData
import Store

/// Drives the PRD Phase: a directed one-shot rather than a conversation. One directed Turn consumes
/// the Design summary as an input, writes the PRD Artifact, and records the Phase complete.
@MainActor
@Observable
public final class PRDModel {
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
    @Fetch var prdPhase: PhaseRow?

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
        self.skill = loadSkill(.toPrd)
        // The `write_artifact` writer is pinned on the Session, not attached per-Turn: the Generate Turn
        // is the Session's *first* Turn, and the per-Turn MCP override is ignored on the first call. PRD
        // is a no-composer directed one-shot — Generate and Regenerate are the only Turns and both are
        // meant to write — so there is no free-form user Turn to protect (unlike Design).
        self.engine = ChatEngine(
            worktree: worktree,
            mode: .readOnly,
            workflowID: workflowID,
            kind: .prd,
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            mcpServers: [Self.artifactServer(command: mcpServerCommand, artifactURL: Self.prdURL(in: workflowDirectory))],
            database: database
        )
        _prdPhase = Fetch(
            wrappedValue: nil,
            CompletedPRDPhaseRequest(workflowID: workflowID),
            animation: .default
        )
    }

    public var prdSavedURL: URL? {
        prdPhase?.artifactPath.map { URL(fileURLWithPath: $0) }
    }

    public var isComplete: Bool { prdPhase != nil }

    public var isSkipped: Bool { isComplete && prdSavedURL == nil }

    public var isIdle: Bool { engine.isIntake }

    public var isBusy: Bool { engine.isRunning }

    public func cancel() {
        engine.cancel()
    }

    public var isGenerateAvailable: Bool {
        !engine.isRunning && !isComplete
    }

    public var isRegenerateAvailable: Bool {
        !engine.isRunning && prdSavedURL != nil
    }

    static func directedPrompt(summaryPath: String) -> String {
        """
        Read the Design summary at \(summaryPath) and produce the complete PRD now, saving it by calling \
        the write_artifact tool with the full markdown document.
        """
    }

    static func regeneratePrompt(summaryPath: String) -> String {
        """
        Re-read the Design summary at \(summaryPath) — it may have been revised since the last run — and \
        produce the complete PRD again, saving it by calling the write_artifact tool with the full \
        markdown document.
        """
    }

    public func skip() {
        guard isGenerateAvailable else { return }
        do {
            try database.completePhase(workflowID: workflowID, kind: "prd", id: uuid(), now: now)
        } catch {
            engine.errorText = error.localizedDescription
        }
    }

    public func unskip() {
        guard isSkipped else { return }
        do {
            try database.reopenPhase(workflowID: workflowID, kind: "prd", now: now)
        } catch {
            engine.errorText = error.localizedDescription
        }
    }

    public func generate() {
        guard isGenerateAvailable else { return }
        runDirectedTurn(prompt: Self.directedPrompt(summaryPath:))
    }

    public func regenerate() {
        guard isRegenerateAvailable else { return }
        runDirectedTurn(prompt: Self.regeneratePrompt(summaryPath:))
    }

    /// Runs the directed Turn and completes the Phase only on a verified `write_artifact` write. The
    /// completion gate is transactional like Allocate's: snapshot the destination file first, run the
    /// Turn, and complete only if it now exists, is non-empty, and (on a Regenerate over the existing
    /// file) its modification time advanced. A Turn that never called the tool surfaces an error and
    /// leaves the Phase incomplete.
    private func runDirectedTurn(prompt: @escaping (String) -> String) {
        engine.errorText = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                let summaryURL = try designSummaryURL()
                let url = Self.prdURL(in: workflowDirectory)
                let before = artifactSnapshot(at: url)
                try await engine.send(
                    prompt(summaryURL.path),
                    inputs: InputBundle(
                        root: summaryURL.deletingLastPathComponent(),
                        relativePaths: [summaryURL.lastPathComponent]
                    )
                )
                guard artifactWasWritten(at: url, since: before) else {
                    throw PRDError.prdNotWritten
                }
                try database.completePhase(
                    workflowID: workflowID, kind: "prd", artifactPath: url.path,
                    id: uuid(), now: now
                )
            } catch {
                engine.errorText = error.localizedDescription
            }
            engine.isRunning = false
        }
    }

    private func designSummaryURL() throws -> URL {
        guard let path = try database.completedArtifactPath(workflowID: workflowID, kind: "design")
        else { throw PRDError.designSummaryMissing }
        return URL(fileURLWithPath: path)
    }

    /// The PRD Artifact's fixed destination — also the `write_artifact` server's `--artifact-path`.
    static func prdURL(in workflowDirectory: URL) -> URL {
        workflowDirectory
            .appending(path: "phases/prd", directoryHint: .isDirectory)
            .appending(path: "prd.md")
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

enum PRDError: LocalizedError {
    case designSummaryMissing
    case prdNotWritten

    var errorDescription: String? {
        switch self {
        case .designSummaryMissing:
            "The completed Design Phase's summary could not be found."
        case .prdNotWritten:
            "The PRD was not saved — the agent must call write_artifact to write it."
        }
    }
}

struct CompletedPRDPhaseRequest: FetchKeyRequest {
    var workflowID: UUID = UUID()

    func fetch(_ db: Database) throws -> PhaseRow? {
        try completedPhaseRow(db, workflowID: workflowID, kind: "prd")
    }
}
