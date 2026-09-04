import Agent
import Chat
import DAGGraphUI
import Dependencies
import Foundation
import Skills
import Observation
import SQLiteData
import Store

/// Drives the Allocate Phase, which forks on a small/big choice pre-selected from the grill's
/// recommendation and overridable by the user.
///
/// - **Big path:** a context-reset checkpoint, so a long, messy grill's context doesn't pollute the
///   carve.
/// - **Small path:** carves straight from the live grill in place, no documents fed.
///
/// `acceptAndWrite()` runs on whichever fork is active — on the small path that resumes the `.design`
/// Session yet still completes the `allocate` Phase (`SessionKind` and `Phase` are independent).
@MainActor
@Observable
public final class AllocateModel {
    /// The big-path engine: a fresh `.allocate` Session that proposes from the PRD + Design summary.
    let engine: ChatEngine

    /// The small-path engine: `kind: .design` + the to-issues Skill, so it resumes the live grill
    /// conversation and carves Issues in place (ADR 0005).
    let smallEngine: ChatEngine

    /// The big-path PRD-Turn engine: `kind: .design` + the to-prd Skill, so it resumes that same live
    /// grill and distils it into the hidden `prd.md` (ADR 0005). Shares the `.design` Session with the
    /// grill and `smallEngine`; its writer is attached per-Turn, never pinned.
    let prdEngine: ChatEngine

    /// The user's explicit fork choice. While `nil` the fork follows the grill's `recommendation`, so
    /// the common case needs no decision; the picker binding pins this the moment the user touches it.
    private var forkOverride: AllocateFork?

    /// Which way Allocate carves Issues — re-choosable whenever Allocate is reopened.
    public var fork: AllocateFork {
        get { forkOverride ?? recommendation?.fork ?? Self.defaultFork }
        set { forkOverride = newValue }
    }

    /// The fallback when the grill left no recommendation. Big is conservative: a PRD checkpoint costs a
    /// little speed, never correctness.
    static let defaultFork: AllocateFork = .big

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
    private let prdSkill: SkillResource

    @ObservationIgnored
    private let mcpServerCommand: String

    @ObservationIgnored
    @Fetch var issues: [IssueRow] = []

    /// The completed `design` Phase, observed so the cutover boundary and message filter update live
    /// once the grill finalizes.
    @ObservationIgnored
    @Fetch var designPhase: PhaseRow?

    /// The PRD checkpoint's live activity, projected from the Turn's content-block rows as the Harness
    /// streams, so the progress panel ticks up without polling. `nil` until the Turn lands.
    @ObservationIgnored
    @Fetch var prdActivityCounts: ActivityCounts?

    /// Ticks once a second only while the PRD checkpoint runs, so its elapsed counts up; an idle
    /// Allocate runs no timer. The same shared `TickClock` behind the Execute/Validate DAG cards.
    @ObservationIgnored
    private let ticker = TickClock()

    public var clock: Date { ticker.now }

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    public init(context: WorkflowContext) {
        self.workflowID = context.workflowID
        self.workflowDirectory = context.workflowDirectory
        self.database = context.database
        self.mcpServerCommand = context.mcpServerCommand
        self.skill = loadSkill(.toIssues)
        self.prdSkill = loadSkill(.toPrd)
        self.engine = ChatEngine(
            worktree: context.worktree,
            mode: .readOnly,
            workflowID: context.workflowID,
            kind: .allocate,
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            database: context.database
        )
        self.smallEngine = ChatEngine(
            worktree: context.worktree,
            mode: .readOnly,
            workflowID: context.workflowID,
            kind: .design,
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            database: context.database
        )
        self.prdEngine = ChatEngine(
            worktree: context.worktree,
            mode: .readOnly,
            workflowID: context.workflowID,
            kind: .design,
            skillFiles: [prdSkill.fileUrl],
            addDirs: [prdSkill.folderUrl],
            database: context.database
        )
        _issues = Fetch(
            wrappedValue: [],
            WorkflowIssuesRequest(workflowID: context.workflowID),
            animation: .default
        )
        _designPhase = Fetch(
            wrappedValue: nil,
            CompletedPhaseRequest(workflowID: context.workflowID, kind: .design),
            animation: .default
        )
        _prdActivityCounts = Fetch(
            wrappedValue: nil,
            PRDCheckpointActivityRequest(workflowID: context.workflowID),
            animation: .default
        )
    }

    /// The engine backing the chosen fork — what the composer, the commit, and the busy/intake
    /// reflections all target.
    var activeEngine: ChatEngine {
        switch fork {
        case .small: smallEngine
        case .big: engine
        }
    }

    /// The Design→Allocate cutover boundary read from the completed `design` Phase, `nil` until it
    /// completes. Turns after this instant are the small-path carve; earlier ones are the grill.
    public var cutoverBoundary: Date? { designPhase?.updatedAt }

    /// The small path's transcript: the shared `.design` conversation filtered to the carve turns,
    /// hiding the grill turns that physically precede them.
    public var carveMessages: [Message] { smallEngine.messages(after: cutoverBoundary) }

    /// The grill's small/big recommendation, parsed from the sentinel on its closing message. Read off
    /// the shared `.design` transcript (`smallEngine` observes it whichever fork is active), so the fork
    /// pre-selects and the rationale surfaces the moment the grill finalizes. `nil` when the grill left
    /// no sentinel, and `fork` falls back to `defaultFork`. The sentinel's only consumer: delete it and
    /// Allocate still works off the static default (severability).
    public var recommendation: AllocateRecommendation? {
        AllocateRecommendation.parse(from: smallEngine.messages)
    }

    /// Big-path empty state: no proposal Session yet, so the surface shows the Propose intake action.
    public var isIntake: Bool { engine.isIntake }

    /// Small-path empty state: the grill exists but nothing is carved yet, so the surface shows the
    /// Carve intake action rather than an empty transcript.
    public var isSmallIntake: Bool {
        carveMessages.isEmpty && !smallEngine.isRunning && smallEngine.errorText == nil
    }

    /// Whether the chat composer is offered. Withheld in the intake and PRD-progress states, so the user
    /// can't message an engine before there's a conversation to continue — doing so silently starts a
    /// stray, context-free Session. Mirrors `AllocateView.content`'s transcript-visible branch.
    public var showsComposer: Bool {
        switch fork {
        case .small: !isSmallIntake
        case .big: !isGeneratingPRD && !isIntake
        }
    }

    /// Whether any fork's agent is mid-Turn — Allocate's contribution to the Workflow's aggregate
    /// running state. All engines are polled, so a fork switched mid-run still reports busy.
    public var isBusy: Bool { engine.isRunning || smallEngine.isRunning || prdEngine.isRunning }

    /// Whether the big path is mid-PRD-Turn, so the surface can show a prominent "generating the PRD"
    /// state ahead of the auto-propose.
    public var isGeneratingPRD: Bool { prdEngine.isRunning }

    /// The PRD checkpoint panel's activity — the same `NodeActivity(counts:running:clock:)` derivation
    /// the Execute/Validate DAG cards use, presented in a panel rather than a footer. `nil` until the
    /// checkpoint Turn lands, so the panel shows a bare spinner rather than a stale grill count.
    public var prdActivity: NodeActivity? {
        guard let counts = prdActivityCounts else { return nil }
        return NodeActivity(counts: counts, running: isGeneratingPRD, clock: clock)
    }

    /// Cancels an in-flight Turn on any fork — Allocate's contribution to the Workflow-level stop-all.
    public func cancel() {
        engine.cancel()
        smallEngine.cancel()
        prdEngine.cancel()
        ticker.stop()
    }

    public var isProposeAvailable: Bool { !engine.isRunning && !prdEngine.isRunning }

    /// The big-path button runs the PRD Turn first, which resumes the live grill, so it needs an
    /// existing `.design` Session.
    public var isBridgeAvailable: Bool {
        prdEngine.session != nil && !engine.isRunning && !prdEngine.isRunning
    }

    /// Regenerating the bridge needs a PRD already written and the live grill to resume.
    public var isRegeneratePRDAvailable: Bool {
        prdSavedURL != nil && prdEngine.session != nil && !engine.isRunning && !prdEngine.isRunning
    }

    /// The small-path carve resumes the live grill, so it needs an existing `.design` Session.
    public var isCarveAvailable: Bool { smallEngine.session != nil && !smallEngine.isRunning }

    public var isAcceptAvailable: Bool { activeEngine.session != nil && !activeEngine.isRunning }

    /// Whether the big path has an auto-propose Session yet — the toolbar offers "Generate PRD & Propose"
    /// before, "Re-propose" / "Regenerate PRD" after.
    public var hasProposed: Bool { engine.session != nil }

    /// The written PRD, present only once the PRD Turn has produced the file — surfaced behind the
    /// "View PRD" disclosure. Reads the fixed path each access; the PRD Turn flipping `isRunning` when
    /// it finishes re-renders the disclosure.
    public var prdSavedURL: URL? { writtenPRDURL() }

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

    /// The small path's opening carve prompt: no documents are fed — the resumed grill conversation
    /// *is* the context.
    static let carvePrompt = """
        Based on the design we just worked through together, propose how to break this into Issues as \
        plain text. Do not write any Issues yet.
        """

    /// The PRD Turn's directed prompt: no documents are fed — the resumed grill conversation is the
    /// context — so it distils that into `prd.md` via `write_artifact`.
    static let prdPrompt = """
        Distil everything we worked through into the complete PRD now, and save it by calling the \
        write_artifact tool with the full markdown document.
        """

    /// Regenerating the bridge: rebuild the PRD from the same grill when the first cut was wrong.
    static let regeneratePRDPrompt = """
        Rebuild the complete PRD from everything we worked through — revise it as needed — and save it \
        again by calling the write_artifact tool with the full markdown document.
        """

    static let commitPrompt = """
        Write the agreed set of Issues now from scratch: make exactly one create_issue call per Issue in \
        the set, even if you already created Issues in an earlier Turn. Recreate every Issue in the agreed \
        set — do not skip any as "already created". Be sure to populate the structured dependencies field if needed.
        """

    /// Re-slice: the big-path iteration when the PRD is fine but the breakdown isn't. Runs an
    /// auto-propose Turn in the `.allocate` Session — started on the first call, resumed thereafter —
    /// reading the already-written `prd.md` and `summary.md` again.
    public func propose() {
        guard isProposeAvailable else { return }
        runTask = engine.run { [self] in
            try await runPropose()
        }
    }

    /// The one big-path button: distil the live grill into `prd.md`, then auto-propose from it — the two
    /// mechanical steps but *not* the commit. A failed PRD Turn throws before propose runs, leaving the
    /// prior Issue set and Phase state intact.
    public func bridgeAndPropose() {
        runBridge(regenerate: false, available: isBridgeAvailable)
    }

    /// Rebuild `prd.md` from the same grill, then re-propose — for when the PRD itself is wrong rather
    /// than just the slicing.
    public func regeneratePRD() {
        runBridge(regenerate: true, available: isRegeneratePRDAvailable)
    }

    /// The shared big-path chain. `engine.isRunning` spans the whole run so the surface reads busy
    /// through both steps, while `prdEngine.isRunning` marks just the PRD-Turn window. Any failure lands
    /// on `engine.errorText` and short-circuits before propose — the prior Issues are never touched.
    private func runBridge(regenerate: Bool, available: Bool) {
        guard available else { return }
        prdEngine.errorText = nil
        prdEngine.isRunning = true
        ticker.start()

        runTask = engine.run { [self] in
            // The explicit calls below end the PRD-Turn window before propose begins; `defer` covers a
            // throw from either step.
            defer {
                prdEngine.isRunning = false
                ticker.stop()
            }
            try await runPRDTurn(regenerate: regenerate)
            prdEngine.isRunning = false
            ticker.stop()
            try await runPropose()
        }
    }

    /// Resume the live grill under the to-prd Skill and write `prd.md` via a per-Turn `write_artifact`
    /// override. Gated like `DesignModel.generateSummary`: snapshot the destination first and count the
    /// Turn only if it left a non-empty file whose modification time advanced, so a Turn that never
    /// called the writer throws.
    private func runPRDTurn(regenerate: Bool) async throws {
        let url = Self.prdURL(in: workflowDirectory)
        let before = artifactSnapshot(at: url)
        try await prdEngine.send(
            regenerate ? Self.regeneratePRDPrompt : Self.prdPrompt,
            overrideMCPServers: [MCPServer.artifactWriter(command: mcpServerCommand, artifactURL: url)]
        )
        guard artifactWasWritten(at: url, since: before) else {
            throw AllocateError.prdNotWritten
        }
    }

    private func runPropose() async throws {
        let design = try artifactURL(kind: .design)
        let prd = writtenPRDURL()
        let relativePaths = [prd, design]
            .compactMap { $0 }
            .map { workflowRelativePath(of: $0.path, under: workflowDirectory) }
        try await engine.send(
            Self.proposePrompt(prdPath: prd?.path, designPath: design.path),
            inputs: InputBundle(root: workflowDirectory, relativePaths: relativePaths)
        )
    }

    /// The small path's opening carve: a resume of the live grill (`kind: .design`) under the to-issues
    /// Skill with **no** documents attached — the grill conversation is the context. Writer-free like
    /// every proposal Turn; only `acceptAndWrite()` commits.
    public func carve() {
        guard isCarveAvailable else { return }
        runTask = smallEngine.run { [self] in
            try await smallEngine.send(Self.carvePrompt)
        }
    }

    /// The single path that commits Issues and completes the Allocate Phase, and the only Turn carrying
    /// the create-issue writer.
    ///
    /// Ordered so a failed or empty commit can never zero out a previously-good set: the prior ids are
    /// snapshotted before the Turn, and are soft-deleted (and the Phase completed) only after a
    /// non-throwing return with a non-empty new write. That ordering yields the completion gate for
    /// free, and gives re-commit — including after a fork switch — its full-rewrite semantics.
    ///
    /// The brief window where old and new Issues coexist with duplicate numbers is harmless (plain
    /// index, no uniqueness constraint) and invisible mid-Turn.
    public func acceptAndWrite() {
        guard isAcceptAvailable else { return }
        let engine = activeEngine
        runTask = engine.run { [self] in
            let priorIDs = Set(try currentIssues().map(\.id))
            try await engine.send(
                Self.commitPrompt,
                overrideMCPServers: [
                    MCPServer.issueWriter(
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
                    workflowID: workflowID, kind: .allocate, id: uuid(), now: now
                )
            }
        }
    }

    /// The PRD bridge's fixed destination, and the `write_artifact` server's `--artifact-path`. A hidden
    /// file rather than a Phase Artifact, so it's located by path, not by a completed Phase row.
    nonisolated static func prdURL(in workflowDirectory: URL) -> URL {
        workflowDirectory
            .appending(path: "phases/prd", directoryHint: .isDirectory)
            .appending(path: "prd.md")
    }

    private func artifactURL(kind: PhaseKind) throws -> URL {
        guard let path = try database.completedArtifactPath(workflowID: workflowID, kind: kind) else {
            throw AllocateError.artifactMissing(kind.rawValue)
        }
        return URL(fileURLWithPath: path)
    }

    /// The written PRD, or `nil` before the PRD Turn produces it — so auto-propose bridges via `prd.md`
    /// when present and falls back to the summary alone when it isn't.
    private func writtenPRDURL() -> URL? {
        let url = Self.prdURL(in: workflowDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func currentIssues() throws -> [IssueRow] {
        try database.read { db in
            try WorkflowIssuesRequest(workflowID: workflowID).fetch(db)
        }
    }
}

enum AllocateError: LocalizedError {
    case artifactMissing(String)
    case prdNotWritten

    var errorDescription: String? {
        switch self {
        case .artifactMissing(let kind):
            "The completed \(kind) Phase's Artifact could not be found."
        case .prdNotWritten:
            "The PRD was not saved — the agent must call write_artifact to write it."
        }
    }
}
