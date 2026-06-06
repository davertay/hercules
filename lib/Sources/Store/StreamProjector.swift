import Dependencies
import Foundation
import IssueReporting
import SQLiteData

/// Consumes the Harness's stream-json output for a single Turn and projects its **text** content
/// into the Workflow database: streamed `text_delta` events are coalesced in memory into one
/// `content_block` row per block (deltas are never stored individually), reconciled against the
/// consolidated `assistant` message, and the Turn is finalized from the `result` event.
///
/// Tool-use and thinking blocks are out of scope here (text-only); non-text and unrecognized
/// events are ignored. A malformed / non-JSON line is a no-op — `ingest` never throws.
public final class TextProjector {
    private let database: any DatabaseWriter
    private let turnID: UUID
    private let uuid: UUIDGenerator
    private let date: DateGenerator

    private struct Block {
        var id: UUID
        var role: String
        var text: String
        var persisted: Bool
    }
    private var blocks: [Int: Block] = [:]

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
        case let .contentBlockStart(index, role):
            blocks[index] = Block(id: uuid(), role: role, text: "", persisted: false)

        case let .textDelta(index, text):
            if blocks[index] == nil {
                blocks[index] = Block(id: uuid(), role: "assistant", text: "", persisted: false)
            }
            blocks[index]?.text += text

        case let .contentBlockStop(index):
            persist(index)

        case let .assistantMessage(role, texts):
            for (index, text) in texts {
                if blocks[index] == nil {
                    blocks[index] = Block(id: uuid(), role: role, text: "", persisted: false)
                }
                blocks[index]?.role = role
                blocks[index]?.text = text
                persist(index)
            }

        case let .result(finalAnswer, isError, durationMs, costUSD):
            finalize(finalAnswer: finalAnswer, isError: isError, durationMs: durationMs, costUSD: costUSD)
        }
    }

    private func persist(_ index: Int) {
        guard let block = blocks[index] else { return }
        let now = date.now
        withErrorReporting {
            try database.write { db in
                if block.persisted {
                    try ContentBlockRow
                        .find(block.id)
                        .update {
                            $0.text = block.text
                            $0.updatedAt = now
                        }
                        .execute(db)
                } else {
                    try ContentBlockRow.insert {
                        ContentBlockRow(
                            id: block.id,
                            turnID: turnID,
                            position: index,
                            role: block.role,
                            kind: "text",
                            text: block.text,
                            createdAt: now,
                            updatedAt: now
                        )
                    }
                    .execute(db)
                }
            }
        }
        blocks[index]?.persisted = true
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

extension TextProjector {
    fileprivate enum Event {
        case contentBlockStart(index: Int, role: String)
        case textDelta(index: Int, text: String)
        case contentBlockStop(index: Int)
        case assistantMessage(role: String, texts: [(index: Int, text: String)])
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
            let texts: [(index: Int, text: String)] = content.enumerated().compactMap { index, item in
                guard item["type"] as? String == "text", let text = item["text"] as? String
                else { return nil }
                return (index, text)
            }
            return .assistantMessage(role: role, texts: texts)

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
                block["type"] as? String == "text"
            else { return nil }
            return .contentBlockStart(index: index, role: "assistant")

        case "content_block_delta":
            guard
                let index = inner["index"] as? Int,
                let delta = inner["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String
            else { return nil }
            return .textDelta(index: index, text: text)

        case "content_block_stop":
            guard let index = inner["index"] as? Int else { return nil }
            return .contentBlockStop(index: index)

        default:
            return nil
        }
    }
}
