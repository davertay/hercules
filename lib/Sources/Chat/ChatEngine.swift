import Agent
import Dependencies
import Foundation
import Observation
import SQLiteData
import Store

/// Drives a user/assistant chat over a single Session. The first `send` starts it; follow-ups resume.
/// Nothing is held in memory for display — the chat renders purely by observing the Workflow database,
/// so the assistant's text streams in live as the Agent projects it (ADR 0003). Hosts (e.g. `Design`)
/// embed the engine and layer their own behavior on top.
@MainActor
@Observable
public final class ChatEngine {
    @ObservationIgnored
    @Dependency(\.agentClient) private var agentClient

    /// Times the grace a declined question is given before its Turn is stopped. Injectable so a test can
    /// hold every engine stopped at once against one deadline it advances itself.
    @ObservationIgnored
    @Dependency(\.continuousClock) private var clock

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let worktree: URL

    @ObservationIgnored
    private let mode: AgentMode

    @ObservationIgnored
    private let workflowID: UUID

    /// Scopes the conversation observation and Session rediscovery to this Workflow's Session of this
    /// kind (ADR 0005).
    @ObservationIgnored
    private let kind: SessionKind

    @ObservationIgnored
    private let skillFiles: [URL]

    @ObservationIgnored
    private let addDirs: [URL]

    /// Pinned at start and re-passed on every resume Turn, like `skillFiles`/`addDirs` (ADR 0001 /
    /// ADR 0004). Empty for surfaces that need none.
    @ObservationIgnored
    private let mcpServers: [MCPServer]

    /// Updates as the Harness streams, which is what makes the assistant's reply appear before the Turn
    /// ends. The scope is stable for the engine's lifetime, so a new Session's Turns are picked up once
    /// its row exists.
    @ObservationIgnored
    @Fetch var conversation = ConversationRequest.Value()

    /// The existing Session row for this `(workflowID, kind)`, *observed* so a Session created after this
    /// engine was constructed is picked up reactively (ADR 0005). Seeded synchronously at construction so
    /// ``session`` is available immediately — Allocate's design-resuming engines are built before their
    /// Session exists.
    @ObservationIgnored
    @Fetch var existingSessionRow: SessionRow?

    /// Pinned once *this* engine's own Turn starts or resumes a Session, taking precedence over the live
    /// ``existingSessionRow`` lookup so follow-ups resume the exact Session this engine drove.
    private var startedSession: Session?

    /// The Session this engine drives, or `nil` if none exists yet: the Turn-pinned Session once this
    /// engine has started one, else resolved live from ``existingSessionRow`` — so a follow-up resumes a
    /// Session a sibling engine created, rather than spuriously starting a second.
    public var session: Session? {
        if let startedSession { return startedSession }
        guard let row = existingSessionRow,
              let mode = AgentMode(rawValue: row.mode),
              let kind = SessionKind(rawValue: row.kind)
        else { return nil }
        return Session(
            id: Session.ID(rawValue: row.id),
            worktree: URL(fileURLWithPath: row.worktreePath),
            mode: mode,
            kind: kind,
            skillFiles: skillFiles,
            addDirs: addDirs,
            mcpServers: mcpServers
        )
    }

    @ObservationIgnored
    public var runTask: Task<Void, Never>?

    /// The stop in flight: the grace a declined question is given to reach the agent and come back,
    /// after which the Turn is cancelled. `nil` unless a stop is unwinding, and retained so a test can
    /// await the stop rather than the wall clock.
    @ObservationIgnored
    private(set) var stopTask: Task<Void, Never>?

    /// Set the moment a stop begins and cleared when the next Turn starts. While it holds, a question
    /// arriving from the Turn being stopped is declined without ever reaching the screen — the model
    /// retries a failed call, and a question the user has just declined coming back as a second card is
    /// exactly what Cancel promises not to do.
    private var isStopping = false

    public var draftText = ""
    public var isRunning = false
    /// Set only for failures that never reach the database (e.g. the Harness binary is missing).
    public var errorText: String?

    /// The `ask_user` calls of the running Turn that are waiting on the user, oldest first.
    ///
    /// Never persisted, and never a Transcript row: a pending question is a blocked process holding an
    /// open request, so it cannot outlive the Turn that owns it, still less a restart.
    private(set) var pendingQuestions: [PendingQuestion] = []

    /// The call the card is showing. One at a time, with any second call queued behind rather than
    /// replacing it: the Harness abandons a call without telling anyone and the model retries, so two
    /// calls waiting at once is a thing that happens, and the one already on screen is the one the user
    /// is mid-answer on.
    var pendingQuestion: PendingQuestion? { pendingQuestions.first }

    /// Lets hosts dismiss transient UI (e.g. a saved-confirmation banner) when fresh chat begins.
    public var onSend: (@MainActor () -> Void)?

    public init(
        worktree: URL,
        mode: AgentMode,
        workflowID: UUID,
        kind: SessionKind,
        skillFiles: [URL] = [],
        addDirs: [URL] = [],
        mcpServers: [MCPServer] = [],
        database: any DatabaseWriter
    ) {
        self.worktree = worktree
        self.mode = mode
        self.workflowID = workflowID
        self.kind = kind
        self.skillFiles = skillFiles
        self.addDirs = addDirs
        self.mcpServers = mcpServers
        self.database = database
        _conversation = Fetch(
            wrappedValue: ConversationRequest.Value(),
            ConversationRequest(workflowID: workflowID, kind: kind),
            animation: .default
        )
        // Skill files and added directories are supplied by the consumer rather than stored (ADR 0004).
        _existingSessionRow = Fetch(
            wrappedValue: try? database.existingSession(workflowID: workflowID, kind: kind),
            ExistingSessionRequest(workflowID: workflowID, kind: kind),
            animation: .default
        )
    }

    /// One user bubble per Turn's prompt, then that Turn's content blocks in order. Built from the
    /// shared `transcriptMessages` so the live chat and the read-only transcript view stay in sync.
    public var messages: [Message] {
        transcriptMessages(turns: conversation.turns, blocks: conversation.blocks)
    }

    /// The messages whose Turn was created strictly after `boundary`. Lets the Allocate small path hide
    /// the grill turns that physically precede the carve in the shared `.design` conversation, so the
    /// surface reads as a clean new Phase. A `nil` boundary applies no filter and returns everything.
    public func messages(after boundary: Date?) -> [Message] {
        guard let boundary else { return messages }
        let turns = conversation.turns.filter { $0.createdAt > boundary }
        let turnIDs = Set(turns.map(\.id))
        let blocks = conversation.blocks.filter { turnIDs.contains($0.turnID) }
        return transcriptMessages(turns: turns, blocks: blocks)
    }

    /// Empty-state condition: a host shows an intake prompt instead of an empty transcript.
    public var isIntake: Bool {
        messages.isEmpty && !isRunning && errorText == nil
    }

    public var isSendDisabled: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning
    }

    public func submit() {
        let prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        draftText = ""
        onSend?()
        runTask = run { [self] in
            try await send(prompt)
        }
    }

    /// Runs one orchestration under the engine's run lifecycle — the wrapper every button-triggered Turn
    /// shares. Returns the task so the host can retain it; storing it in ``runTask`` (as ``submit()``
    /// does) additionally routes it through ``cancel()``.
    @discardableResult
    public func run(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        errorText = nil
        isRunning = true
        // A fresh Turn is not the stopped one, so its questions are the user's to answer again.
        isStopping = false
        return Task {
            do {
                try await operation()
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
        }
    }

    /// How long a declined question is given to reach the agent and come back before the Turn is stopped
    /// from under it.
    ///
    /// The dismissal has to travel down to the blocked call, be returned as the tool's error-flagged
    /// result, and be written into the Harness's own session record — a round trip of a poll interval and
    /// a little I/O, not of a human, which is why this is a couple of seconds and not a couple of
    /// minutes. Overshooting costs nothing anyone can see: the stop is already on screen and the Turn is
    /// one nobody is waiting on. Undershooting costs only the better message — the teardown closes the
    /// MCP transport itself and the Harness records the call as `Connection closed`, which is well-formed,
    /// just less use to the agent on the next resume.
    static let declinedQuestionGrace: Duration = .seconds(2)

    /// Stops an in-flight Turn, declining any question of it still waiting on the user first. A no-op
    /// when idle, and the engine is ready for a fresh Turn afterwards. Routed up through the chat-host
    /// models to the Workflow-level stop-all, so the toolbar's Stop and the card's own Cancel are one
    /// path with one outcome for the agent — they differ only in how much else goes down with them.
    public func cancel() {
        stop(afterDecliningAQuestion: false)
    }

    /// The whole stop sequence, shared by the toolbar's Stop and the card's Cancel.
    ///
    /// `afterDecliningAQuestion` is set by the card, which has already answered its own call on the way
    /// in; every *other* question of the Turn is declined here. Either way the order is the same and the
    /// order is the point: the waiting calls are answered, and only after the grace that lets those
    /// answers come back is the Turn cancelled, so the Harness records complete `tool_use`/`tool_result`
    /// pairs rather than calls torn down mid-flight.
    ///
    /// ``isRunning`` is cleared ahead of all of it, so the UI reflects the stop at once rather than when
    /// the cancelled Turn has finished unwinding. The Turn itself takes the ordinary cancellation path
    /// and reads as a stopped Turn afterwards, which is the truth of it.
    ///
    /// Nothing here waits on anything, so several engines stopped in one pass — a Workflow-wide Stop with
    /// two Sessions blocked on questions at once — decline together and share the one grace between them
    /// rather than queueing one behind the other.
    private func stop(afterDecliningAQuestion declined: Bool) {
        guard !isStopping else { return }
        isStopping = true
        isRunning = false
        // Evaluated first and on its own: whatever else this Turn had waiting has just been answered too,
        // and it needs the same grace the card's own call does.
        let dismissedAny = dismissPendingQuestions()
        let hadQuestion = declined || dismissedAny
        // Captured, so a Turn the user starts during the grace is not the one the stop lands on.
        let stopping = runTask
        guard hadQuestion else {
            stopping?.cancel()
            return
        }
        stopTask = Task { [clock] in
            try? await clock.sleep(for: Self.declinedQuestionGrace)
            stopping?.cancel()
        }
    }

    /// Renders `questions` as the live card and suspends the call that asked them until the user submits
    /// an answer — the Chat's half of the round trip, and the reason ``QuestionHandler`` is a callback:
    /// one invocation, one answer, no correlation to arrange.
    ///
    /// A call arriving after a stop has begun is declined where it stands and never reaches the screen.
    private func ask(_ questions: [Question]) async -> Answer {
        guard !isStopping else { return .cancelled }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            pendingQuestions.append(
                PendingQuestion(
                    id: id,
                    questions: questions,
                    onCancel: { [weak self] in self?.stop(afterDecliningAQuestion: true) }
                ) { [weak self] answer in
                    self?.pendingQuestions.removeAll { $0.id == id }
                    continuation.resume(returning: answer)
                }
            )
        }
    }

    /// Ends every question still waiting when a Turn does, dismissing its card, and reports whether there
    /// was one.
    ///
    /// A question outlives its Turn only when the Turn ended without the call coming back for its answer
    /// — a stop, a torn-down Harness — and a card left on screen afterwards would be a live control with
    /// nobody on the other end of it. The call, if it is still there to hear it, is told what a dismissal
    /// tells it; an answer nobody is waiting on is inert.
    @discardableResult
    private func dismissPendingQuestions() -> Bool {
        let outstanding = pendingQuestions
        pendingQuestions = []
        for question in outstanding { question.resolve(.cancelled) }
        return !outstanding.isEmpty
    }

    /// Starts the Session on the first call and resumes it thereafter, returning once the Turn ends.
    /// `inputs` carries reference documents: their root is exposed to the Harness and listed in the
    /// rendered prompt (ADR 0004).
    /// `overrideMCPServers` overrides the Session's pinned servers for this single resume Turn only;
    /// `nil` falls back to `session.mcpServers` (ADR 0001). Ignored on the first call, which starts
    /// the Session with its configured (pinned) servers.
    public func send(_ prompt: String, inputs: InputBundle? = nil, overrideMCPServers: [MCPServer]? = nil) async throws {
        // Read per Turn, so revoking trust applies to this Workflow's long-lived chat Session at its very
        // next Turn rather than only to a Session started afterwards.
        let trustsRepositorySettings = database.trustsRepositorySettings(workflowID: workflowID)
        // Whether a human is watching this Turn — whether it is *attended* — is asked per Turn, like the
        // trust setting above, and answered today from the kind of Session it belongs to: the Chat-backed
        // kinds are the ones with a card to render a question on. Offering to answer is what gives the
        // Turn the question tool and the rules for using it, so an unattended kind driven through a Chat
        // offers nothing and its agent has nothing to block on. Behind-the-scenes runs never reach here
        // at all — they go through the Agent directly.
        let onQuestion: QuestionHandler? = kind.isAttended
            ? { @Sendable [weak self] questions in await self?.ask(questions) ?? .cancelled }
            : nil
        // Whatever the Turn's outcome, no question of it may stay on screen past it.
        defer { dismissPendingQuestions() }
        if let existing = session {
            startedSession = try await agentClient.send(
                SendRequest(
                    prompt: prompt,
                    session: existing,
                    inputs: inputs,
                    database: database,
                    mcpServers: overrideMCPServers,
                    trustsRepositorySettings: trustsRepositorySettings,
                    onQuestion: onQuestion
                )
            )
        } else {
            startedSession = try await agentClient.start(
                StartRequest(
                    prompt: prompt,
                    worktree: worktree,
                    mode: mode,
                    inputs: inputs,
                    database: database,
                    workflowID: workflowID,
                    kind: kind,
                    skillFiles: skillFiles,
                    addDirs: addDirs,
                    mcpServers: mcpServers,
                    trustsRepositorySettings: trustsRepositorySettings,
                    onQuestion: onQuestion
                )
            )
        }
    }
}

/// Reads one surface's Turns and content blocks in one transaction so they stay consistent mid-Turn.
/// The scope resolves to a set of Session IDs first, then reads those Sessions' Turns and blocks:
/// - `.kind` — every Session of `kind` in `workflowID`, driving the live chat (ADR 0005).
/// - `.session` — a single Session, driving the read-only transcript view so a sibling Session of the
///   same kind (e.g. another Issue's `execute` run) can't bleed its conversation in.
struct ConversationRequest: FetchKeyRequest {
    enum Scope: Hashable, Sendable {
        case kind(workflowID: UUID, kind: SessionKind)
        case session(UUID)
    }

    var scope: Scope

    init(workflowID: UUID, kind: SessionKind) {
        scope = .kind(workflowID: workflowID, kind: kind)
    }

    init(sessionID: UUID) {
        scope = .session(sessionID)
    }

    struct Value: Equatable, Sendable {
        var turns: [TurnRow] = []
        var blocks: [ContentBlockRow] = []
    }

    func fetch(_ db: Database) throws -> Value {
        let sessionIDs: Set<UUID>
        switch scope {
        case let .kind(workflowID, kind):
            sessionIDs = Set(
                try SessionRow
                    .where { $0.workflowID.eq(workflowID) }
                    .where { $0.kind.eq(kind.rawValue) }
                    .fetchAll(db)
                    .map(\.id)
            )
        case let .session(sessionID):
            sessionIDs = [sessionID]
        }
        let turns = try TurnRow.fetchAll(db).filter { sessionIDs.contains($0.sessionID) }
        let turnIDs = Set(turns.map(\.id))
        let blocks = try ContentBlockRow.fetchAll(db).filter { turnIDs.contains($0.turnID) }
        return Value(turns: turns, blocks: blocks)
    }
}
