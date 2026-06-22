import Dependencies
import DependenciesTestSupport
import Foundation
import SQLiteData
import Testing

@testable import Store

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@Suite(
    "StreamProjector",
    .dependency(\.uuid, .incrementing),
    .dependency(\.date, .constant(fixedDate))
)
struct StreamProjectorTests {

    @Test func coalescesTextDeltasIntoSingleBlock() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_stop","index":0}"#))

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.id == UUID(0))
        #expect(block.turnID == turnID)
        #expect(block.position == 0)
        #expect(block.role == "assistant")
        #expect(block.kind == "text")
        #expect(block.text == "Hello, world")
    }

    @Test func reconcilesCoalescedTextAgainstConsolidatedMessage() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        // A partial/garbled stream is superseded by the authoritative consolidated message.
        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello, wrl"}}"#))
        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello, world"}]}}"#))

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.count == 1)
        #expect(blocks.first?.text == "Hello, world")
    }

    @Test func consolidatedMessageWithoutStreamingInsertsBlock() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Just the result"}]}}"#))

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.count == 1)
        #expect(blocks.first?.text == "Just the result")
        #expect(blocks.first?.position == 0)
    }

    @Test func finalizesTurnFromResultEvent() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        projector.ingest(Self.line(#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"total_cost_usd":0.25,"result":"All done."}"#))

        let turns = try database.read { db in try TurnRow.fetchAll(db) }
        let turn = try #require(turns.first)
        #expect(turn.finalAnswer == "All done.")
        #expect(turn.isError == false)
        #expect(turn.durationMs == 1234)
        #expect(turn.costUSD == 0.25)
    }

    @Test func errorResultFlagsTurn() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        projector.ingest(Self.line(#"{"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":50,"result":""}"#))

        let turns = try database.read { db in try TurnRow.fetchAll(db) }
        let turn = try #require(turns.first)
        #expect(turn.isError == true)
        #expect(turn.finalAnswer == "")
        #expect(turn.costUSD == nil)
    }

    @Test func askUserQuestionSignalsInterruptThenPausesCleanly() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        let askJSON = #"{"questions":[{"header":"Goal","multiSelect":false,"options":[{"label":"A"}],"question":"What?"}]}"#

        let asked = projector.ingest(Self.line(
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":\#(askJSON)}]}}"#
        ))
        #expect(asked == .askedQuestion)

        // The Harness's auto-error result for the unanswerable call is noise and dropped.
        let suppressed = projector.ingest(Self.line(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Answer questions?","is_error":true}]}}"#
        ))
        #expect(suppressed == .none)

        // The interrupt reads back errored but is a deliberate pause: `.completed`, Turn recorded clean.
        let completed = projector.ingest(Self.line(
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":1,"result":""}"#
        ))
        #expect(completed == .completed)

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == "tool_use")
        #expect(blocks.first?.toolName == "AskUserQuestion")
        #expect(blocks.first?.text == askJSON)

        let turn = try #require(try database.read { db in try TurnRow.fetchAll(db) }.first)
        #expect(turn.isError == false)
    }

    @Test func ordinaryResultSignalsCompletedAndOrdinaryToolResultIsKept() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        // Absent a pending question, tool results are projected and the result signals completion.
        let toolResult = projector.ingest(Self.line(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"contents"}]}}"#
        ))
        #expect(toolResult == .none)
        let completed = projector.ingest(Self.line(#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"result":"ok"}"#))
        #expect(completed == .completed)

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.contains { $0.kind == "tool_result" && $0.text == "contents" })
    }

    @Test func malformedAndIrrelevantLinesAreIgnored() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        projector.ingest(Data("this is not json".utf8))
        projector.ingest(Self.line("{ broken json"))
        projector.ingest(Self.line(#"{"type":"stream_event"}"#))            // missing inner event
        projector.ingest(Self.line(#"{"no":"type"}"#))                       // no type
        projector.ingest(Self.line(#"{"type":"system","subtype":"init"}"#))  // irrelevant event

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.isEmpty)
        let turns = try database.read { db in try TurnRow.fetchAll(db) }
        let turn = try #require(turns.first)
        #expect(turn.finalAnswer == nil)
    }

    // MARK: - Thinking, tool-use, and tool-result blocks

    @Test func coalescesThinkingDeltasIntoSingleBlock() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me "}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"check the repo."}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_stop","index":0}"#))

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.kind == "thinking")
        #expect(block.role == "assistant")
        #expect(block.text == "Let me check the repo.")
        #expect(block.toolName == nil)
    }

    @Test func coalescesToolUseInputJSONAndReconcilesAgainstConsolidatedMessage() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"README.md\"}"}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_stop","index":0}"#))
        // The consolidated assistant message supersedes the streamed partial JSON.
        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"path":"README.md"}}]}}"#))

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.kind == "tool_use")
        #expect(block.role == "assistant")
        #expect(block.toolName == "Read")
        #expect(block.text == #"{"path":"README.md"}"#)
    }

    @Test func recordsToolResultFromUserMessage() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        projector.ingest(Self.line(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"Hercules readme"}]}]}}"#))

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.kind == "tool_result")
        #expect(block.role == "user")
        #expect(block.text == "Hercules readme")
        #expect(block.toolName == nil)
    }

    @Test func toolResultAcceptsPlainStringContent() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        projector.ingest(Self.line(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"plain output"}]}}"#))

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.first?.kind == "tool_result")
        #expect(blocks.first?.text == "plain output")
    }

    @Test func interleavedMessagesGetContiguousMonotonicPositions() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        // Assistant message: thinking + tool call (stream indices restart at 0 per message).
        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Reading."}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#))
        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Reading."},{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}]}}"#))
        // Tool result comes back as a user message — its index restarts at 0 too.
        projector.ingest(Self.line(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"done"}]}}"#))
        // Final assistant message with the answer text — index restarts at 0 again.
        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"All set."}}"#))
        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All set."}]}}"#))

        let blocks = try database.read { db in
            try ContentBlockRow.order(by: \.position).fetchAll(db)
        }
        #expect(blocks.map(\.position) == [0, 1, 2, 3])
        #expect(blocks.map(\.kind) == ["thinking", "tool_use", "tool_result", "text"])
        #expect(blocks.map(\.text) == ["Reading.", "{}", "done", "All set."])
        #expect(blocks.map(\.role) == ["assistant", "assistant", "user", "assistant"])
    }

    /// The real Harness wire format — a consolidated `assistant` message per block, parallel
    /// `tool_use`, interleaved `tool_result`s — which the old position math collided into duplicate
    /// `(turnID, position)` rows that crashed the chat's ForEach.
    @Test func perBlockConsolidatedMessagesAndParallelToolsGetUniquePositions() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = StreamProjector(database: database, turnID: turnID)

        // First assistant message: thinking + two parallel Read tool calls.
        projector.ingest(Self.streamEvent(#"{"type":"message_start","message":{"role":"assistant"}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Reading both."}}"#))
        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Reading both."}]}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_stop","index":0}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\":\"a\"}"}}"#))
        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"a"}}]}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_stop","index":1}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_2","name":"Read","input":{}}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\":\"b\"}"}}"#))
        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"b"}}]}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_stop","index":2}"#))
        // Tool results arrive interleaved, before message_stop.
        projector.ingest(Self.line(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"A"}]}}"#))
        projector.ingest(Self.line(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"B"}]}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"message_stop"}"#))
        // Second assistant message: the answer — stream index restarts at 0.
        projector.ingest(Self.streamEvent(#"{"type":"message_start","message":{"role":"assistant"}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done."}}"#))
        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#))
        projector.ingest(Self.streamEvent(#"{"type":"content_block_stop","index":0}"#))

        let blocks = try database.read { db in
            try ContentBlockRow.order(by: \.position).fetchAll(db)
        }
        // No duplicate (turnID, position) rows, and everything in arrival order.
        #expect(blocks.map(\.position) == [0, 1, 2, 3, 4, 5])
        #expect(Set(blocks.map(\.position)).count == blocks.count)
        #expect(blocks.map(\.kind) == ["thinking", "tool_use", "tool_use", "tool_result", "tool_result", "text"])
        #expect(blocks.map(\.role) == ["assistant", "assistant", "assistant", "user", "user", "assistant"])
        #expect(blocks.map(\.text) == ["Reading both.", #"{"file_path":"a"}"#, #"{"file_path":"b"}"#, "A", "B", "Done."])
        #expect(blocks.map(\.toolName) == [nil, "Read", "Read", nil, nil, nil])
    }

    // MARK: - Helpers

    private static func line(_ json: String) -> Data { Data(json.utf8) }

    private static func streamEvent(_ innerJSON: String) -> Data {
        Data(#"{"type":"stream_event","event":\#(innerJSON)}"#.utf8)
    }

    /// A fresh database seeded with one workflow → session → turn, returned with the turn's id.
    private static func seededWorkflow() throws -> (any DatabaseWriter, UUID) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)", isDirectory: true)
        let database = try openWorkflowDatabase(at: dir)
        let workflowID = UUID(-1)
        let sessionID = UUID(-2)
        let turnID = UUID(-3)
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try SessionRow.insert {
                SessionRow(
                    id: sessionID,
                    workflowID: workflowID,
                    worktreePath: "/repo",
                    mode: "readOnly",
                    kind: "design",
                    createdAt: fixedDate,
                    updatedAt: fixedDate
                )
            }
            .execute(db)
            try TurnRow.insert {
                TurnRow(id: turnID, sessionID: sessionID, userPrompt: "hi", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
        }
        return (database, turnID)
    }
}
