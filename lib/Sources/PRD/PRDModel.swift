import Agent
import Chat
import Dependencies
import Foundation
import Material
import Observation
import SQLiteData
import Store

/// Drives the PRD Phase: a directed one-shot rather than a conversation. The shared `ChatEngine` is
/// configured for a `readOnly` Session under the bundled to-prd Skill with the repo as cwd (so the
/// agent grounds the PRD in real code); this model layers the Phase orchestration on top — one
/// directed Turn that consumes the Design summary as an input, writes the PRD Artifact, and records
/// the Phase as complete.
@MainActor
@Observable
public final class PRDModel {
    /// The shared chat engine, configured for the PRD Session. There is no composer — the engine is
    /// driven solely by `generate()` — but its streaming Transcript is the progress display.
    let engine: ChatEngine

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    /// The Workflow's root directory (`~/.hercules/workflows/<id>/`); the PRD Artifact is written
    /// beneath it at `phases/prd/prd.md`.
    @ObservationIgnored
    private let workflowDirectory: URL

    @ObservationIgnored
    private let skill: SkillResource

    /// Live view of this Workflow's completed `prd` phase row. The saved confirmation is derived
    /// from it rather than held in memory, so the result survives closing and reopening the window.
    @ObservationIgnored
    @Fetch var prdPhase: PhaseRow?

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    public init(worktree: URL, workflowID: UUID, workflowDirectory: URL, database: any DatabaseWriter) {
        self.workflowID = workflowID
        self.workflowDirectory = workflowDirectory
        self.database = database
        self.skill = loadSkill(.toPrd)
        self.engine = ChatEngine(
            worktree: worktree,
            mode: .readOnly,
            workflowID: workflowID,
            kind: .prd,
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            database: database
        )
        _prdPhase = Fetch(
            wrappedValue: nil,
            CompletedPRDPhaseRequest(workflowID: workflowID),
            animation: .default
        )
    }

    /// The saved PRD's location once the Phase has completed. Drives the saved confirmation (with
    /// its Reveal in Finder button).
    public var prdSavedURL: URL? {
        prdPhase?.artifactPath.map { URL(fileURLWithPath: $0) }
    }

    /// True before any generation has produced a Transcript — drives the idle action instead of it.
    public var isIdle: Bool { engine.isIntake }

    /// Whether the single "Generate PRD from Design Summary" action can run: not while a Turn is in
    /// flight, and not once the Phase is complete (re-running is the separate Regenerate action).
    public var isGenerateAvailable: Bool {
        !engine.isRunning && prdSavedURL == nil
    }

    /// The directed instruction the one-shot Turn runs with; the heavy behavioral instructions live
    /// in the to-prd Skill.
    static func directedPrompt(summaryPath: String) -> String {
        "Read the Design summary at \(summaryPath) and produce the complete PRD now as a markdown document."
    }

    /// Runs the one directed Turn: reads the Design summary's location from the completed Design
    /// Phase row (the single source of truth), sends the directed prompt with the summary as an
    /// input — exposing only the summary's directory to the Harness, not the whole Workflow
    /// directory — then writes the Turn's final answer to `phases/prd/prd.md` and flips the `prd`
    /// phase row to complete with the Artifact path, unlocking Allocate.
    public func generate() {
        guard isGenerateAvailable else { return }
        engine.errorText = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                let summaryURL = try designSummaryURL()
                try await engine.send(
                    Self.directedPrompt(summaryPath: summaryURL.path),
                    inputs: InputBundle(
                        root: summaryURL.deletingLastPathComponent(),
                        relativePaths: [summaryURL.lastPathComponent]
                    )
                )
                guard let session = engine.session else { throw PRDError.sessionUnavailable }
                let finalAnswer = try database.latestFinalAnswer(forSession: session.id.rawValue) ?? ""
                let url = try writePRD(finalAnswer)
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

    /// The Design summary's location, read at generate-time from the completed Design Phase row's
    /// Artifact path.
    private func designSummaryURL() throws -> URL {
        let row = try database.read { db in
            try PhaseRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq("design") }
                .where { $0.status.eq("complete") }
                .where { !$0.isDeleted }
                .fetchOne(db)
        }
        guard let path = row?.artifactPath else { throw PRDError.designSummaryMissing }
        return URL(fileURLWithPath: path)
    }

    /// Writes the PRD markdown to `phases/prd/prd.md` under the Workflow directory, creating the
    /// intermediate directories and overwriting any existing file.
    private func writePRD(_ markdown: String) throws -> URL {
        let url = workflowDirectory
            .appending(path: "phases/prd", directoryHint: .isDirectory)
            .appending(path: "prd.md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

enum PRDError: LocalizedError {
    case designSummaryMissing
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .designSummaryMissing:
            "The completed Design Phase's summary could not be found."
        case .sessionUnavailable:
            "The PRD Session could not be started."
        }
    }
}

/// Fetches a Workflow's completed, non-deleted `prd` phase row. Deriving the saved confirmation
/// from this observation means completing the Phase shows it live, and reopening the window shows
/// it again.
struct CompletedPRDPhaseRequest: FetchKeyRequest {
    var workflowID: UUID = UUID()

    func fetch(_ db: Database) throws -> PhaseRow? {
        try PhaseRow
            .where { $0.workflowID.eq(workflowID) }
            .where { $0.kind.eq("prd") }
            .where { $0.status.eq("complete") }
            .where { !$0.isDeleted }
            .fetchOne(db)
    }
}
