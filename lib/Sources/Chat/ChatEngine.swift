import Agent
import Dependencies
import Foundation
import Observation
import SQLiteData
import Store

/// Drives a user/assistant chat over a single Session. The first `send` starts the Session; follow-ups
/// resume it. Nothing is held in memory for display — the chat is rendered purely by observing the
/// Workflow database, so the assistant's text streams in live as the Agent projects it (ADR 0003). A
/// host (e.g. `Design`) embeds the engine and layers its own behavior on top.
@MainActor
@Observable
public final class ChatEngine {
    @ObservationIgnored
    @Dependency(\.agentClient) private var agentClient

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

    /// Pinned once the first Turn starts so follow-ups resume rather than start a new Session.
    public private(set) var session: Session?

    @ObservationIgnored
    public var runTask: Task<Void, Never>?

    public var draftText = ""
    public var isRunning = false
    /// Set only for failures that never reach the database (e.g. the Harness binary is missing).
    public var errorText: String?

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
        // Rediscover an existing Session so a follow-up resumes it and reopening shows prior history.
        // Skill files and added directories are supplied by the consumer rather than stored (ADR 0005).
        if let row = try? database.existingSession(workflowID: workflowID, kind: kind),
           let mode = AgentMode(rawValue: row.mode),
           let kind = SessionKind(rawValue: row.kind) {
            session = Session(
                id: Session.ID(rawValue: row.id),
                worktree: URL(fileURLWithPath: row.worktreePath),
                mode: mode,
                kind: kind,
                skillFiles: skillFiles,
                addDirs: addDirs,
                mcpServers: mcpServers
            )
        }
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
        errorText = nil
        isRunning = true
        runTask = Task { [self] in
            do {
                try await send(prompt)
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
        }
    }

    /// Cancels an in-flight Turn and clears `isRunning` so the UI reflects the stop immediately. The
    /// submit task clears the flag in its own completion once the cancelled Turn unwinds; this clears it
    /// up front rather than waiting for that. A no-op when idle, and the engine is ready for a fresh Turn
    /// afterwards. Routed up through the chat-host models to the Workflow-level stop-all.
    public func cancel() {
        runTask?.cancel()
        isRunning = false
    }

    /// Starts the Session on the first call and resumes it thereafter, returning once the Turn ends.
    /// `inputs` carries reference documents: their root is exposed to the Harness and listed in the
    /// rendered prompt (ADR 0004).
    /// `overrideMCPServers` overrides the Session's pinned servers for this single resume Turn only;
    /// `nil` falls back to `session.mcpServers` (ADR 0001). Ignored on the first call, which starts
    /// the Session with its configured (pinned) servers.
    public func send(_ prompt: String, inputs: InputBundle? = nil, overrideMCPServers: [MCPServer]? = nil) async throws {
        if let existing = session {
            session = try await agentClient.send(
                SendRequest(
                    prompt: prompt,
                    session: existing,
                    inputs: inputs,
                    database: database,
                    mcpServers: overrideMCPServers
                )
            )
        } else {
            session = try await agentClient.start(
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
                    mcpServers: mcpServers
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
