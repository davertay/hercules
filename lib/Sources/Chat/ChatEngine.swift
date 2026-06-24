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
    public struct Message: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case user, assistant, thinking, toolUse, toolResult }
        public let id: String
        public let kind: Kind
        public let text: String
        /// Set only on `.toolUse` rows.
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

    /// One user bubble per Turn's prompt, then that Turn's content blocks in order.
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

    /// `nil` to skip the block (empty text/thinking).
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
/// Scoped to Sessions of `kind` in `workflowID` so different-kind Sessions don't bleed transcripts.
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
