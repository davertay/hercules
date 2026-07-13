import Agent
import Chat
import Dependencies
import Foundation
import Skills
import Observation
import SQLiteData
import Store

/// Which way Allocate carves Issues, chosen live once the user has seen how the grill went.
public enum AllocateFork: String, Sendable, CaseIterable, Identifiable {
    /// Carve straight from the live grill conversation — no PRD, no document round-trip.
    case small
    /// Propose from the PRD and Design summary in a fresh Session — the document-bridged path.
    case big

    public var id: Self { self }
}

/// Drives the Allocate Phase, which forks live on a small/big choice the user makes here (guided, in a
/// later slice, by the grill's recommendation; for now a static default the user can flip).
///
/// - **Big path:** a fresh `.allocate` Session reads the PRD + Design summary and proposes an Issue
///   breakdown as text (`propose()`), writer-free like every chat Turn.
/// - **Small path:** an engine built with `kind: .design` + the to-issues Skill *resumes the live grill*
///   and carves in place (`carve()`), no documents fed — the grill conversation is the context. The
///   Allocate view filters that shared conversation to Turns after the Design cutover boundary, hiding
///   the grill turns so it reads as a clean new Phase.
///
/// Either way, only `acceptAndWrite()` carries the create-issue writer (on its commit Turn), committing
/// the agreed set transactionally: snapshot the prior ids, write, then clear the snapshot and complete
/// the `allocate` Phase only if the write produced a new, non-empty set — so a failed or empty commit
/// leaves the prior set intact and doesn't falsely unlock Execute (its Artifact is rows, not a file).
/// The commit runs on whichever fork's engine is active; on the small path that resumes the `.design`
/// Session yet still completes the `allocate` Phase (`SessionKind` and `Phase` are independent).
@MainActor
@Observable
public final class AllocateModel {
    /// The big-path engine: a fresh `.allocate` Session that proposes from the PRD + Design summary.
    let engine: ChatEngine

    /// The small-path engine: `kind: .design` + the to-issues Skill, so it rediscovers and resumes the
    /// live grill conversation and carves Issues in place (ADR 0005).
    let smallEngine: ChatEngine

    /// The fork the user has chosen. A static default for now — the recommendation that pre-selects it
    /// lands in a later slice — re-choosable when Allocate is reopened.
    public var fork: AllocateFork = .big

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

    /// The completed `design` Phase, observed so the small path's cutover boundary and message filter
    /// update live once the grill finalizes.
    @ObservationIgnored
    @Fetch var designPhase: PhaseRow?

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
        // The same to-issues Skill over `kind: .design`, so this engine resumes the live grill Session
        // and carves from it rather than starting fresh.
        self.smallEngine = ChatEngine(
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
        _designPhase = Fetch(
            wrappedValue: nil,
            CompletedDesignPhaseRequest(workflowID: workflowID),
            animation: .default
        )
    }

    /// The engine backing the currently chosen fork — the one the composer, the commit, and the busy /
    /// intake reflections all target.
    var activeEngine: ChatEngine {
        switch fork {
        case .small: smallEngine
        case .big: engine
        }
    }

    /// The Design→Allocate cutover boundary read from the completed `design` Phase, `nil` until it
    /// completes. Turns created after this instant are the small-path carve; earlier ones are the grill.
    public var cutoverBoundary: Date? { designPhase?.updatedAt }

    /// The small path's transcript: the shared `.design` conversation filtered to the carve turns, so the
    /// grill turns that physically precede them are hidden.
    public var carveMessages: [Message] { smallEngine.messages(after: cutoverBoundary) }

    /// Big-path empty state: no proposal Session yet, so the surface shows the Propose intake action.
    public var isIntake: Bool { engine.isIntake }

    /// Small-path empty state: the grill exists but nothing has been carved yet, so the surface shows the
    /// Carve intake action rather than an empty transcript.
    public var isSmallIntake: Bool {
        carveMessages.isEmpty && !smallEngine.isRunning && smallEngine.errorText == nil
    }

    /// Whether either fork's agent is mid-Turn — the Allocate contribution to the Workflow's aggregate
    /// running state. Both engines are polled so a fork switched mid-run is still reported as busy.
    public var isBusy: Bool { engine.isRunning || smallEngine.isRunning }

    /// Cancels an in-flight Turn on either fork — the Allocate contribution to the Workflow-level
    /// stop-all. A no-op on whichever engine is idle.
    public func cancel() {
        engine.cancel()
        smallEngine.cancel()
    }

    public var isProposeAvailable: Bool { !engine.isRunning }

    /// The small-path carve resumes the live grill, so it needs an existing `.design` Session.
    public var isCarveAvailable: Bool { smallEngine.session != nil && !smallEngine.isRunning }

    public var isAcceptAvailable: Bool { activeEngine.session != nil && !activeEngine.isRunning }

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

    /// The small path's opening carve prompt: no documents are fed — the resumed grill conversation *is*
    /// the context — so it just asks for the breakdown of what was already discussed.
    static let carvePrompt = """
        Based on the design we just worked through together, propose how to break this into Issues as \
        plain text. Do not write any Issues yet.
        """

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

    /// The small path's opening carve: a resume of the live grill (`kind: .design`) under the to-issues
    /// Skill with **no** documents attached — the grill conversation is the context. Writer-free like
    /// every proposal Turn; only `acceptAndWrite()` commits.
    public func carve() {
        guard isCarveAvailable else { return }
        smallEngine.errorText = nil
        smallEngine.isRunning = true

        runTask = Task { [self] in
            do {
                try await smallEngine.send(Self.carvePrompt)
            } catch {
                smallEngine.errorText = error.localizedDescription
            }
            smallEngine.isRunning = false
        }
    }

    /// The single path that commits Issues and completes the Allocate Phase, structured transactionally so
    /// a failed or empty commit can never zero out a previously-good set:
    ///
    /// 1. Snapshot the live Issue ids before sending the commit prompt.
    /// 2. Run the commit Turn on the active fork's engine — the only Turn that carries the create-issue
    ///    writer, via the per-turn `mcpServers` override.
    /// 3. The new write is the Issues whose ids aren't in the snapshot.
    /// 4. Only on a non-throwing return with a non-empty new write, soft-delete the snapshotted ids and
    ///    complete the Phase. `runTurn` throws on a failed/crashed Turn, so a broken commit lands in
    ///    `catch` before any delete/complete — the transactional ordering yields the completion gate for
    ///    free, and the old set stays fully intact. This also gives re-commit (including after a fork
    ///    switch) its full-rewrite semantics: the prior set is snapshotted and cleared regardless of which
    ///    fork wrote it.
    ///
    /// The brief window where old and new Issues coexist with duplicate numbers is harmless (plain index,
    /// no uniqueness constraint) and invisible mid-Turn.
    public func acceptAndWrite() {
        guard isAcceptAvailable else { return }
        let engine = activeEngine
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

/// The completed, non-deleted `design` Phase — its `updatedAt` is the Design→Allocate cutover boundary
/// the small path filters the shared conversation against.
struct CompletedDesignPhaseRequest: FetchKeyRequest {
    var workflowID: UUID = UUID()

    func fetch(_ db: Database) throws -> PhaseRow? {
        try completedPhaseRow(db, workflowID: workflowID, kind: "design")
    }
}
