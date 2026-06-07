import Dependencies
import Foundation
import IssueReporting
import SQLiteData

/// Consumes the Harness's stream-json output for a single Turn and projects its content into the
/// Workflow database: one `content_block` row per block — `text`, `thinking`, `tool_use` (name +
/// input), and `tool_result` — reconciled against the consolidated `assistant`/`user` messages, and
/// the Turn finalized from the `result` event.
///
/// Streamed deltas are coalesced in memory and flushed to the row in place (never stored
/// individually): `text_delta` and `thinking_delta` append text, and `input_json_delta` appends the
/// tool-call input JSON. A malformed / non-JSON line is a no-op — `ingest` never throws.
public final class StreamProjector {
    private let database: any DatabaseWriter
    private let turnID: UUID
    private let uuid: UUIDGenerator
    private let date: DateGenerator

    private struct Block {
        var id: UUID
        var role: String
        var kind: String
        var toolName: String?
        var text: String
        var persisted: Bool
    }

    /// Blocks keyed by their absolute position within the Turn. A Turn spans multiple messages
    /// (assistant text/tool calls, then user tool results, then more assistant content), and the
    /// Harness restarts its content-block `index` at 0 for each one, so positions are tracked
    /// Turn-wide rather than per message.
    private var blocks: [Int: Block] = [:]

    /// Next free absolute position. Advances past each consolidated message's blocks.
    private var nextPosition = 0

    /// Base position for the message currently streaming; `nil` between messages. Set lazily on the
    /// first streamed event of a message so positions stay contiguous even without a `message_start`.
    private var liveBase: Int?

    public init(database: any DatabaseWriter, turnID: UUID) {
        @Dependency(\.uuid) var uuid
        @Dependency(\.date) var date
        self.database = database
        self.turnID = turnID
        self.uuid = uuid
        self.date = date
    }

    public func ingest(_ line: Data) {
        guard let event = Self.decode(line) else { return }
        switch event {
        case let .contentBlockStart(index, kind, role, toolName):
            let position = base() + index
            blocks[position] = Block(
                id: uuid(), role: role, kind: kind, toolName: toolName, text: "", persisted: false
            )

        case let .textDelta(index, text):
            append(index: index, text: text, defaultKind: "text")

        case let .thinkingDelta(index, text):
            append(index: index, text: text, defaultKind: "thinking")

        case let .inputJSONDelta(index, partialJSON):
            append(index: index, text: partialJSON, defaultKind: "tool_use")

        case let .contentBlockStop(index):
            persist(base() + index)

        case let .assistantMessage(decoded):
            let messageBase = base()
            reconcile(decoded, base: messageBase)
            nextPosition = messageBase + decoded.count
            liveBase = nil

        case let .toolResults(decoded):
            reconcile(decoded, base: nextPosition)
            nextPosition += decoded.count

        case let .result(finalAnswer, isError, durationMs, costUSD):
            finalize(finalAnswer: finalAnswer, isError: isError, durationMs: durationMs, costUSD: costUSD)
        }
    }

    /// The base position for the currently-streaming message, set lazily on first use.
    private func base() -> Int {
        if liveBase == nil { liveBase = nextPosition }
        return liveBase!
    }

    private func append(index: Int, text: String, defaultKind: String) {
        let position = base() + index
        if blocks[position] == nil {
            blocks[position] = Block(
                id: uuid(), role: "assistant", kind: defaultKind, toolName: nil, text: "", persisted: false
            )
        }
        blocks[position]?.text += text
    }

    /// Overwrites the streamed (or absent) blocks with the authoritative consolidated message,
    /// inserting any block that never streamed.
    private func reconcile(_ decodedBlocks: [DecodedBlock], base: Int) {
        for (offset, decoded) in decodedBlocks.enumerated() {
            let position = base + offset
            if blocks[position] == nil {
                blocks[position] = Block(
                    id: uuid(), role: decoded.role, kind: decoded.kind,
                    toolName: decoded.toolName, text: decoded.text, persisted: false
                )
            } else {
                blocks[position]?.role = decoded.role
                blocks[position]?.kind = decoded.kind
                blocks[position]?.toolName = decoded.toolName
                blocks[position]?.text = decoded.text
            }
            persist(position)
        }
    }

    private func persist(_ position: Int) {
        guard let block = blocks[position] else { return }
        let now = date.now
        withErrorReporting {
            try database.write { db in
                if block.persisted {
                    try ContentBlockRow
                        .find(block.id)
                        .update {
                            $0.kind = block.kind
                            $0.toolName = block.toolName
                            $0.text = block.text
                            $0.updatedAt = now
                        }
                        .execute(db)
                } else {
                    try ContentBlockRow.insert {
                        ContentBlockRow(
                            id: block.id,
                            turnID: turnID,
                            position: position,
                            role: block.role,
                            kind: block.kind,
                            text: block.text,
                            toolName: block.toolName,
                            createdAt: now,
                            updatedAt: now
                        )
                    }
                    .execute(db)
                }
            }
        }
        blocks[position]?.persisted = true
    }

    /// Flags the Turn as errored when the Harness fails before — or instead of — emitting a
    /// `result` event (non-zero exit, crash, cancellation). Leaves `finalAnswer` untouched; the
    /// diagnostic detail travels with the `AgentError` the Agent throws.
    public func recordFailure(durationMs: Int?) {
        let now = date.now
        withErrorReporting {
            try database.write { db in
                try TurnRow
                    .find(turnID)
                    .update {
                        $0.isError = true
                        $0.durationMs = durationMs
                        $0.updatedAt = now
                    }
                    .execute(db)
            }
        }
    }

    private func finalize(finalAnswer: String?, isError: Bool, durationMs: Int?, costUSD: Double?) {
        let now = date.now
        withErrorReporting {
            try database.write { db in
                try TurnRow
                    .find(turnID)
                    .update {
                        $0.finalAnswer = finalAnswer
                        $0.isError = isError
                        $0.durationMs = durationMs
                        $0.costUSD = costUSD
                        $0.updatedAt = now
                    }
                    .execute(db)
            }
        }
    }
}

extension StreamProjector {
    /// A content block as carried by a consolidated `assistant`/`user` message.
    fileprivate struct DecodedBlock {
        var kind: String
        var role: String
        var toolName: String?
        var text: String
    }

    fileprivate enum Event {
        case contentBlockStart(index: Int, kind: String, role: String, toolName: String?)
        case textDelta(index: Int, text: String)
        case thinkingDelta(index: Int, text: String)
        case inputJSONDelta(index: Int, partialJSON: String)
        case contentBlockStop(index: Int)
        case assistantMessage(blocks: [DecodedBlock])
        case toolResults(blocks: [DecodedBlock])
        case result(finalAnswer: String?, isError: Bool, durationMs: Int?, costUSD: Double?)
    }

    fileprivate static func decode(_ line: Data) -> Event? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }

        switch type {
        case "stream_event":
            guard
                let inner = object["event"] as? [String: Any],
                let innerType = inner["type"] as? String
            else { return nil }
            return decodeStreamEvent(innerType, inner)

        case "assistant":
            guard let message = object["message"] as? [String: Any] else { return nil }
            let role = message["role"] as? String ?? "assistant"
            let content = message["content"] as? [[String: Any]] ?? []
            // Every item is kept so array offsets stay aligned with the streamed block indices.
            let blocks = content.map { decodeAssistantBlock($0, role: role) }
            return .assistantMessage(blocks: blocks)

        case "user":
            guard let message = object["message"] as? [String: Any] else { return nil }
            let content = message["content"] as? [[String: Any]] ?? []
            // Tool results are the only user-message content the Transcript records; the human
            // prompt already lives on the Turn row.
            let blocks = content.compactMap(decodeToolResult)
            return blocks.isEmpty ? nil : .toolResults(blocks: blocks)

        case "result":
            return .result(
                finalAnswer: object["result"] as? String,
                isError: object["is_error"] as? Bool ?? false,
                durationMs: object["duration_ms"] as? Int,
                costUSD: object["total_cost_usd"] as? Double
            )

        default:
            return nil
        }
    }

    private static func decodeStreamEvent(_ innerType: String, _ inner: [String: Any]) -> Event? {
        switch innerType {
        case "content_block_start":
            guard
                let index = inner["index"] as? Int,
                let block = inner["content_block"] as? [String: Any],
                let blockType = block["type"] as? String
            else { return nil }
            switch blockType {
            case "text":
                return .contentBlockStart(index: index, kind: "text", role: "assistant", toolName: nil)
            case "thinking":
                return .contentBlockStart(index: index, kind: "thinking", role: "assistant", toolName: nil)
            case "tool_use":
                return .contentBlockStart(
                    index: index, kind: "tool_use", role: "assistant",
                    toolName: block["name"] as? String
                )
            default:
                return nil
            }

        case "content_block_delta":
            guard
                let index = inner["index"] as? Int,
                let delta = inner["delta"] as? [String: Any],
                let deltaType = delta["type"] as? String
            else { return nil }
            switch deltaType {
            case "text_delta":
                guard let text = delta["text"] as? String else { return nil }
                return .textDelta(index: index, text: text)
            case "thinking_delta":
                guard let text = delta["thinking"] as? String else { return nil }
                return .thinkingDelta(index: index, text: text)
            case "input_json_delta":
                guard let json = delta["partial_json"] as? String else { return nil }
                return .inputJSONDelta(index: index, partialJSON: json)
            default:
                return nil
            }

        case "content_block_stop":
            guard let index = inner["index"] as? Int else { return nil }
            return .contentBlockStop(index: index)

        default:
            return nil
        }
    }

    private static func decodeAssistantBlock(_ item: [String: Any], role: String) -> DecodedBlock {
        switch item["type"] as? String {
        case "thinking":
            return DecodedBlock(kind: "thinking", role: role, toolName: nil, text: item["thinking"] as? String ?? "")
        case "tool_use":
            return DecodedBlock(
                kind: "tool_use", role: role, toolName: item["name"] as? String,
                text: jsonString(item["input"]) ?? ""
            )
        default:
            // Treat anything else (including `text`) as plain text so positions stay aligned.
            return DecodedBlock(kind: "text", role: role, toolName: nil, text: item["text"] as? String ?? "")
        }
    }

    private static func decodeToolResult(_ item: [String: Any]) -> DecodedBlock? {
        guard item["type"] as? String == "tool_result" else { return nil }
        return DecodedBlock(kind: "tool_result", role: "user", toolName: nil, text: toolResultText(item["content"]))
    }

    /// A tool result's content is either a plain string or an array of content blocks; flatten the
    /// array's text, falling back to a JSON dump of anything unexpected.
    private static func toolResultText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let items = content as? [[String: Any]] {
            return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return jsonString(content) ?? ""
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard
            let value,
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
