import Agent
import Dependencies
import Foundation
import Observation
import SQLiteData
import Store

/// Drives a user/assistant chat over a single Session. The first `send` starts the Session with the
/// configured mode, worktree, and Skill files; follow-ups resume it. Nothing about the conversation
/// is held in memory for display — the chat is rendered purely by observing the Workflow database, so
/// the assistant's text streams in live as the Agent projects it (ADR 0003).
///
/// The engine owns no window chrome and no Phase orchestration; a host (e.g. `Design`) embeds it and
/// layers its own behavior on top.
@MainActor
@Observable
public final class ChatEngine {
    public struct Message: Identifiable, Equatable, Sendable {
        /// What a chat row renders: the user's prompt, the assistant's text, or — in the live
        /// tool-call timeline — the agent's thinking, a tool invocation, or a tool's result.
        public enum Kind: Equatable, Sendable { case user, assistant, thinking, toolUse, toolResult }
        public let id: String
        public let kind: Kind
        public let text: String
        /// The invoked tool's name; set only on `.toolUse` rows.
        public let toolName: String?
        public let isError: Bool

        public init(id: String, kind: Kind, text: String, toolName: String? = nil, isError: Bool = false) {
            self.id = id
            self.kind = kind
            self.text = text
            self.toolName = toolName
            self.isError = isError
        }
    }

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

    /// The surface this engine serves. Scopes both the conversation observation and the Session
    /// rediscovery to this Workflow's Session of this kind (ADR 0005).
    @ObservationIgnored
    private let kind: SessionKind

    @ObservationIgnored
    private let skillFiles: [URL]

    @ObservationIgnored
    private let addDirs: [URL]

    /// Live view of this surface's Turns and their content blocks — only those belonging to a Session
    /// of this engine's kind in its Workflow. Updates as the Harness streams, which is what makes the
    /// assistant's reply appear before the Turn ends. The scope is stable for the engine's lifetime,
    /// so a freshly-created Session's Turns are picked up automatically once its row exists.
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

    /// Invoked when the user initiates a new send via the composer. Hosts use it to dismiss transient
    /// UI (e.g. a saved-confirmation banner) the moment fresh chat activity begins.
    public var onSend: (@MainActor () -> Void)?

    public init(
        worktree: URL,
        mode: AgentMode,
        workflowID: UUID,
        kind: SessionKind,
        skillFiles: [URL] = [],
        addDirs: [URL] = [],
        database: any DatabaseWriter
    ) {
        self.worktree = worktree
        self.mode = mode
        self.workflowID = workflowID
        self.kind = kind
        self.skillFiles = skillFiles
        self.addDirs = addDirs
        self.database = database
        _conversation = Fetch(
            wrappedValue: ConversationRequest.Value(),
            ConversationRequest(workflowID: workflowID, kind: kind),
            animation: .default
        )
        // Rediscover this surface's existing Session so a follow-up resumes it rather than starting a
        // new one, and reopening shows prior history. The persisted row carries the pinned worktree
        // and mode; the Skill files and added directories are fixed per surface and supplied by the
        // consumer rather than stored (ADR 0005).
        if let row = try? database.existingSession(workflowID: workflowID, kind: kind),
           let mode = AgentMode(rawValue: row.mode),
           let kind = SessionKind(rawValue: row.kind) {
            session = Session(
                id: Session.ID(rawValue: row.id),
                worktree: URL(fileURLWithPath: row.worktreePath),
                mode: mode,
                kind: kind,
                skillFiles: skillFiles,
                addDirs: addDirs
            )
        }
    }

    /// The conversation reconstructed from the database: one user bubble per Turn's prompt, then that
    /// Turn's content blocks in order — assistant text, thinking, tool calls, and tool results — so
    /// the chat shows a live tool-call timeline as the Turn runs.
    public var messages: [Message] {
        let turns = conversation.turns.sorted { $0.createdAt < $1.createdAt }
        let blocksByTurn = Dictionary(grouping: conversation.blocks) { $0.turnID }

        var result: [Message] = []
        for turn in turns {
            result.append(
                Message(id: "\(turn.id.uuidString)/user", kind: .user, text: turn.userPrompt)
            )
            let blocks = (blocksByTurn[turn.id] ?? []).sorted { $0.position < $1.position }
            var hasAssistantText = false
            for block in blocks {
                guard let message = Self.message(for: block, isError: turn.isError) else { continue }
                if message.kind == .assistant { hasAssistantText = true }
                result.append(message)
            }
            // Surface a bare failure only when the errored Turn produced no assistant text to carry it.
            if !hasAssistantText, turn.isError {
                result.append(
                    Message(id: "\(turn.id.uuidString)/assistant", kind: .assistant, text: "Turn failed.", isError: true)
                )
            }
        }
        return result
    }

    /// Maps one content block to its chat row, or `nil` to skip it (empty text/thinking).
    private static func message(for block: ContentBlockRow, isError: Bool) -> Message? {
        let id = "\(block.turnID.uuidString)/\(block.position)"
        switch block.kind {
        case "text":
            guard !block.text.isEmpty else { return nil }
            return Message(id: id, kind: .assistant, text: block.text, isError: isError)
        case "thinking":
            guard !block.text.isEmpty else { return nil }
            return Message(id: id, kind: .thinking, text: block.text)
        case "tool_use":
            return Message(id: id, kind: .toolUse, text: block.text, toolName: block.toolName)
        case "tool_result":
            return Message(id: id, kind: .toolResult, text: block.text)
        default:
            return nil
        }
    }

    /// True before any conversation exists and while the engine is idle — the empty-state condition a
    /// host uses to show an intake prompt instead of an empty transcript.
    public var isIntake: Bool {
        messages.isEmpty && !isRunning && errorText == nil
    }

    public var isSendDisabled: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning
    }

    /// Submits the draft as a new Turn: clears the composer, then runs the start-or-resume send.
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

    /// The single start-or-resume send operation: starts the Session on the first call and resumes it
    /// thereafter, projecting the Turn into the database as it streams. Returns once the Turn ends.
    /// Hosts may call it directly (e.g. with a canned prompt) and await `runTask`.
    public func send(_ prompt: String) async throws {
        if let existing = session {
            session = try await agentClient.send(
                SendRequest(prompt: prompt, session: existing, database: database)
            )
        } else {
            session = try await agentClient.start(
                StartRequest(
                    prompt: prompt,
                    worktree: worktree,
                    mode: mode,
                    database: database,
                    workflowID: workflowID,
                    kind: kind,
                    skillFiles: skillFiles,
                    addDirs: addDirs
                )
            )
        }
    }
}

/// Reads one surface's Turns and their content blocks in one transaction so the two stay consistent
/// as the Workflow database changes mid-Turn. Scoped to Sessions of `kind` in `workflowID`, so two
/// Sessions of different kinds in the same Workflow don't bleed into each other's transcript.
struct ConversationRequest: FetchKeyRequest {
    var workflowID: UUID = UUID()
    var kind: SessionKind = .design

    struct Value: Equatable, Sendable {
        var turns: [TurnRow] = []
        var blocks: [ContentBlockRow] = []
    }

    func fetch(_ db: Database) throws -> Value {
        let sessionIDs = Set(
            try SessionRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq(kind.rawValue) }
                .fetchAll(db)
                .map(\.id)
        )
        let turns = try TurnRow.fetchAll(db).filter { sessionIDs.contains($0.sessionID) }
        let turnIDs = Set(turns.map(\.id))
        let blocks = try ContentBlockRow.fetchAll(db).filter { turnIDs.contains($0.turnID) }
        return Value(turns: turns, blocks: blocks)
    }
}
