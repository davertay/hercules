import Foundation
import Store

/// A single rendered row of a conversation — a user/assistant bubble, a thinking row, a tool call, or
/// a tool result. Built from projected `TurnRow`/`ContentBlockRow` data and consumed by the bubble
/// views, so the live chat and the read-only transcript view render from one source of truth.
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

/// Builds the conversation's display rows: one user bubble per Turn's prompt, then that Turn's content
/// blocks in order. The single source of truth shared by `ChatEngine` (live chat) and the read-only
/// transcript view, so the two surfaces can't drift apart.
func transcriptMessages(turns: [TurnRow], blocks: [ContentBlockRow]) -> [Message] {
    let sortedTurns = turns.sorted { $0.createdAt < $1.createdAt }
    let blocksByTurn = Dictionary(grouping: blocks) { $0.turnID }

    var result: [Message] = []
    for turn in sortedTurns {
        result.append(
            Message(id: "\(turn.id.uuidString)/user", kind: .user, text: turn.userPrompt)
        )
        let turnBlocks = (blocksByTurn[turn.id] ?? []).sorted { $0.position < $1.position }
        var hasAssistantText = false
        for block in turnBlocks {
            guard let message = message(for: block, isError: turn.isError) else { continue }
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
func message(for block: ContentBlockRow, isError: Bool) -> Message? {
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
