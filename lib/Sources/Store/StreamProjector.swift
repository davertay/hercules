import Dependencies
import Foundation
import IssueReporting
import SQLiteData

/// Projects the Harness's stream-json output for one Turn into the database: one `content_block` row
/// per block, deltas coalesced in memory and flushed in place, the Turn finalized from `result`. A
/// malformed line is a no-op — `ingest` never throws.
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

    /// The Harness restarts content-block `index` at 0 per assistant message, so index alone isn't
    /// unique within a Turn — pair it with the message ordinal.
    private struct StreamKey: Hashable {
        var messageOrdinal: Int
        var index: Int
    }

    private var blocks: [Int: Block] = [:]

    /// Maps a streamed block to its absolute position so its deltas, its stop, and the consolidated
    /// message that supersedes it all reconcile onto the same row.
    private var positionByStreamKey: [StreamKey: Int] = [:]

    /// Allocated in arrival order so positions stay monotonic across assistant and interleaved
    /// tool-result messages.
    private var nextPosition = 0

    /// Bumped when a `content_block_start` reuses an index already seen — the Harness's only signal
    /// that a new message has begun.
    private var messageOrdinal = 0

    private var reconciledCount = 0

    /// The Harness can't draw `AskUserQuestion`'s picker, so it auto-errors the call and barrels on. The
    /// Agent interrupts on `.askedQuestion`; while set, the auto-error result is dropped and the Turn's
    /// own interrupt-`is_error` result is recorded as a clean stop.
    private var interruptedForQuestion = false

    /// The text of the most recent `is_error` `result`. The Harness writes its failure reason here (on
    /// stdout) and then exits non-zero with an empty stderr, so this is the only place that reason lives
    /// — the `TerminationClassifier` reads it to give `harnessFailed` a meaningful detail.
    public private(set) var lastErrorResult: String?

    public init(database: any DatabaseWriter, turnID: UUID) {
        @Dependency(\.uuid) var uuid
        @Dependency(\.date) var date
        self.database = database
        self.turnID = turnID
        self.uuid = uuid
        self.date = date
    }

    /// Projects one stream line and reports what the Agent should do next.
    @discardableResult
    public func ingest(_ line: Data) -> StreamSignal {
        guard let event = Self.decode(line) else { return .none }
        switch event {
        case let .contentBlockStart(index, kind, role, toolName):
            let position = streamPosition(forIndex: index, isStart: true)
            if blocks[position] == nil {
                blocks[position] = Block(
                    id: uuid(), role: role, kind: kind, toolName: toolName, text: "", persisted: false
                )
            } else {
                blocks[position]?.role = role
                blocks[position]?.kind = kind
                blocks[position]?.toolName = toolName
            }

        case let .textDelta(index, text):
            append(index: index, text: text, defaultKind: "text")

        case let .thinkingDelta(index, text):
            append(index: index, text: text, defaultKind: "thinking")

        case let .inputJSONDelta(index, partialJSON):
            append(index: index, text: partialJSON, defaultKind: "tool_use")

        case let .contentBlockStop(index):
            persist(streamPosition(forIndex: index, isStart: false))

        case let .assistantMessage(decoded):
            // The Harness sends the consolidated message one block at a time, each superseding the next
            // streamed block in order.
            for block in decoded {
                let position = streamPosition(forIndex: reconciledCount, isStart: false)
                reconciledCount += 1
                upsert(position: position, block: block)
            }
            // Interrupt only on the first question, so a later message can't re-trigger it.
            if !interruptedForQuestion,
               decoded.contains(where: { $0.kind == "tool_use" && $0.toolName == "AskUserQuestion" }) {
                interruptedForQuestion = true
                return .askedQuestion
            }

        case let .toolResults(decoded):
            // After a question, the only result left is the call's auto-error; drop it.
            guard !interruptedForQuestion else { return .none }
            // Tool results are their own blocks; they never reuse a streamed index.
            for block in decoded {
                upsert(position: allocatePosition(), block: block)
            }

        case let .result(finalAnswer, isError, durationMs, costUSD):
            finalize(finalAnswer: finalAnswer, isError: isError, durationMs: durationMs, costUSD: costUSD)
            return .completed
        }
        return .none
    }

    /// A `content_block_start` whose index was already seen means the Harness restarted indices for a
    /// new message, so the ordinal advances first.
    private func streamPosition(forIndex index: Int, isStart: Bool) -> Int {
        if isStart, positionByStreamKey[StreamKey(messageOrdinal: messageOrdinal, index: index)] != nil {
            messageOrdinal += 1
            reconciledCount = 0
        }
        let key = StreamKey(messageOrdinal: messageOrdinal, index: index)
        if let position = positionByStreamKey[key] { return position }
        let position = allocatePosition()
        positionByStreamKey[key] = position
        return position
    }

    private func allocatePosition() -> Int {
        defer { nextPosition += 1 }
        return nextPosition
    }

    private func append(index: Int, text: String, defaultKind: String) {
        let position = streamPosition(forIndex: index, isStart: false)
        if blocks[position] == nil {
            blocks[position] = Block(
                id: uuid(), role: "assistant", kind: defaultKind, toolName: nil, text: "", persisted: false
            )
        }
        blocks[position]?.text += text
    }

    /// Overwrites (or inserts) the block at `position` with the consolidated block, covering blocks
    /// that never streamed.
    private func upsert(position: Int, block decoded: DecodedBlock) {
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

    private func persist(_ position: Int) {
        guard let block = blocks[position] else { return }
        let now = date.now
        withErrorReporting {
            try database.write { db in
                if block.persisted {
                    try ContentBlockRow
                        .find(block.id)
                        .update {
                            $0.role = block.role
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

    /// Flags the Turn errored when the Harness fails before emitting a `result` (non-zero exit, crash,
    /// cancellation). The diagnostic detail travels with the `AgentError` the Agent throws.
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
        // An interrupt-to-await-a-question reads back as an errored result, but it's a clean pause.
        let isError = isError && !interruptedForQuestion
        if isError { lastErrorResult = finalAnswer }
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

/// What the Agent should do after the `StreamProjector` consumes a line.
public enum StreamSignal: Equatable, Sendable {
    case none
    /// Interrupt the Turn so the rendered card can be answered, then resume with the selection.
    case askedQuestion
    /// The Turn's `result` landed; the Harness can be closed.
    case completed
}

extension StreamProjector {
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
            // Keep every item so offsets stay aligned with the streamed block indices.
            let blocks = content.map { decodeAssistantBlock($0, role: role) }
            return .assistantMessage(blocks: blocks)

        case "user":
            guard let message = object["message"] as? [String: Any] else { return nil }
            let content = message["content"] as? [[String: Any]] ?? []
            // Tool results are the only user-message content recorded; the prompt lives on the Turn row.
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

    /// A tool result's content is either a plain string or an array of content blocks.
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
