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
        public enum Role: Sendable { case user, assistant }
        public let id: String
        public let role: Role
        public let text: String
        public let isError: Bool
    }

    @ObservationIgnored
    @Dependency(\.agentClient) private var agentClient

    @ObservationIgnored
    @Dependency(\.designSkillFile) private var skillFile

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let worktree: URL

    @ObservationIgnored
    private let workflowID: UUID

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

    public init(worktree: URL, workflowID: UUID, database: any DatabaseWriter) {
        self.worktree = worktree
        self.workflowID = workflowID
        self.database = database
    }

    /// The conversation reconstructed from the database: one user bubble per Turn's prompt followed
    /// by that Turn's assistant text (the Turn's text content-blocks, in order).
    public var messages: [Message] {
        let turns = conversation.turns.sorted { $0.createdAt < $1.createdAt }
        let blocksByTurn = Dictionary(grouping: conversation.blocks) { $0.turnID }

        var result: [Message] = []
        for turn in turns {
            result.append(
                Message(id: "\(turn.id.uuidString)/user", role: .user, text: turn.userPrompt, isError: false)
            )
            let assistantText = (blocksByTurn[turn.id] ?? [])
                .sorted { $0.position < $1.position }
                .map(\.text)
                .joined(separator: "\n\n")
            if !assistantText.isEmpty {
                result.append(
                    Message(id: "\(turn.id.uuidString)/assistant", role: .assistant, text: assistantText, isError: turn.isError)
                )
            } else if turn.isError {
                result.append(
                    Message(id: "\(turn.id.uuidString)/assistant", role: .assistant, text: "Turn failed.", isError: true)
                )
            }
        }
        return result
    }

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
        errorText = nil
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
