import Agent
import Dependencies
import Foundation
import Observation
import SQLiteData
import Store

/// Drives the Design Phase chat. The first submit starts a `readOnly` Session under the bundled
/// grill-me Skill with the repo as cwd; follow-up submits resume that same Session. Nothing about
/// the conversation is held in memory for display — the chat is rendered purely by observing the
/// Workflow database, so the assistant's text streams in live as the Agent projects it (ADR 0003).
@MainActor
@Observable
public final class DesignModel {
    public struct Message: Identifiable, Equatable, Sendable {
        /// What a chat row renders: the user's prompt, the assistant's text, or — new in the live
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
    @Dependency(\.designSkillFile) private var skillFile

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let worktree: URL

    @ObservationIgnored
    private let workflowID: UUID

    /// The Workflow's root directory (`~/.hercules/workflows/<id>/`); the Design summary Artifact is
    /// written beneath it at `phases/design/summary.md`.
    @ObservationIgnored
    private let workflowDirectory: URL

    /// Live view of the Workflow's Turns and their text content-blocks. Updates as the Harness
    /// streams, which is what makes the assistant's reply appear before the Turn ends.
    @ObservationIgnored
    @Fetch(ConversationRequest(), animation: .default)
    var conversation = ConversationRequest.Value()

    /// Pinned once the first Turn completes so follow-ups resume rather than start a new Session.
    @ObservationIgnored
    private var session: Session?

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    public var draftText = ""
    public var isRunning = false
    /// Set only for failures that never reach the database (e.g. the Harness binary is missing).
    public var errorText: String?
    /// The saved summary's location once a finalization Turn has written it. Drives the saved
    /// confirmation (with its Reveal in Finder button); cleared when new chat activity starts.
    public var summarySavedURL: URL?

    public init(worktree: URL, workflowID: UUID, workflowDirectory: URL, database: any DatabaseWriter) {
        self.worktree = worktree
        self.workflowID = workflowID
        self.workflowDirectory = workflowDirectory
        self.database = database
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

    public var isIntake: Bool {
        messages.isEmpty && !isRunning && errorText == nil
    }

    public var isSendDisabled: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning
    }

    /// Whether the "Generate Design Summary" action applies: the conversation is underway, so a
    /// Session exists to resume with the finalization instruction.
    public var isGenerateSummaryAvailable: Bool {
        session != nil
    }

    public func submit() {
        let prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        draftText = ""
        errorText = nil
        summarySavedURL = nil
        isRunning = true

        let skillFiles = skillFile.map { [$0] } ?? []
        // Expose the Skill's own directory so the agent can read the files it references (ADR 0004).
        let addDirs = skillFile.map { [$0.deletingLastPathComponent()] } ?? []

        runTask = Task { [self] in
            do {
                if let existing = session {
                    session = try await agentClient.send(
                        SendRequest(prompt: prompt, session: existing, database: database)
                    )
                } else {
                    session = try await agentClient.start(
                        StartRequest(
                            prompt: prompt,
                            worktree: worktree,
                            mode: .readOnly,
                            database: database,
                            workflowID: workflowID,
                            skillFiles: skillFiles,
                            addDirs: addDirs
                        )
                    )
                }
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
        }
    }

    /// The canned instruction the finalization Turn resumes the Session with.
    static let finalizationPrompt = "Produce the complete design summary now as a markdown document."

    /// Resumes the Session with the finalization instruction, then writes that Turn's final answer to
    /// `phases/design/summary.md` and flips the Design `phase` row to complete with the Artifact path.
    /// Re-running overwrites the file and updates the same row.
    public func generateSummary() {
        guard let session, !isRunning else { return }
        errorText = nil
        summarySavedURL = nil
        isRunning = true

        runTask = Task { [self] in
            do {
                _ = try await agentClient.send(
                    SendRequest(prompt: Self.finalizationPrompt, session: session, database: database)
                )
                let url = try writeSummary(finalAnswer(forSession: session.id.rawValue))
                try recordDesignComplete(artifactPath: url.path)
                summarySavedURL = url
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
        }
    }

    /// The final answer of the Session's most recent Turn — the finalization Turn just projected.
    private func finalAnswer(forSession sessionID: UUID) throws -> String {
        let turn = try database.read { db in
            try TurnRow
                .where { $0.sessionID.eq(sessionID) }
                .order { $0.createdAt.desc() }
                .fetchOne(db)
        }
        return turn?.finalAnswer ?? ""
    }

    /// Writes the summary markdown to `phases/design/summary.md` under the Workflow directory,
    /// creating the intermediate directories and overwriting any existing file.
    private func writeSummary(_ markdown: String) throws -> URL {
        let url = workflowDirectory
            .appending(path: "phases/design", directoryHint: .isDirectory)
            .appending(path: "summary.md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Flips the Design `phase` row to complete with the Artifact path, inserting the row the first
    /// time and updating it on a re-run.
    private func recordDesignComplete(artifactPath: String) throws {
        let timestamp = now
        try database.write { db in
            let existing = try PhaseRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq("design") }
                .fetchOne(db)
            if let existing {
                try PhaseRow
                    .find(existing.id)
                    .update {
                        $0.status = "complete"
                        $0.artifactPath = #bind(artifactPath)
                        $0.updatedAt = timestamp
                    }
                    .execute(db)
            } else {
                try PhaseRow.insert {
                    PhaseRow(
                        id: uuid(),
                        workflowID: workflowID,
                        kind: "design",
                        status: "complete",
                        artifactPath: artifactPath,
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
                .execute(db)
            }
        }
    }
}

/// Reads a Session's Turns and their text content-blocks in one transaction so the two stay
/// consistent as the Workflow database changes mid-Turn.
struct ConversationRequest: FetchKeyRequest {
    struct Value: Equatable, Sendable {
        var turns: [TurnRow] = []
        var blocks: [ContentBlockRow] = []
    }

    func fetch(_ db: Database) throws -> Value {
        Value(
            turns: try TurnRow.fetchAll(db),
            blocks: try ContentBlockRow.fetchAll(db)
        )
    }
}
