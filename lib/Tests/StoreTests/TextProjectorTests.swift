import Dependencies
import DependenciesTestSupport
import Foundation
import SQLiteData
import Testing

@testable import Store

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@Suite(
    "TextProjector",
    .dependency(\.uuid, .incrementing),
    .dependency(\.date, .constant(fixedDate))
)
struct TextProjectorTests {

    @Test func coalescesTextDeltasIntoSingleBlock() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = TextProjector(database: database, turnID: turnID)

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
        let projector = TextProjector(database: database, turnID: turnID)

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
        let projector = TextProjector(database: database, turnID: turnID)

        projector.ingest(Self.line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Just the result"}]}}"#))

        let blocks = try database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.count == 1)
        #expect(blocks.first?.text == "Just the result")
        #expect(blocks.first?.position == 0)
    }

    @Test func finalizesTurnFromResultEvent() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = TextProjector(database: database, turnID: turnID)

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
        let projector = TextProjector(database: database, turnID: turnID)

        projector.ingest(Self.line(#"{"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":50,"result":""}"#))

        let turns = try database.read { db in try TurnRow.fetchAll(db) }
        let turn = try #require(turns.first)
        #expect(turn.isError == true)
        #expect(turn.finalAnswer == "")
        #expect(turn.costUSD == nil)
    }

    @Test func malformedAndIrrelevantLinesAreIgnored() throws {
        let (database, turnID) = try Self.seededWorkflow()
        let projector = TextProjector(database: database, turnID: turnID)

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

    // MARK: - Helpers

    private static func line(_ json: String) -> Data { Data(json.utf8) }

    private static func streamEvent(_ innerJSON: String) -> Data {
        Data(#"{"type":"stream_event","event":\#(innerJSON)}"#.utf8)
    }

    /// Opens a fresh on-disk Workflow database seeded with one workflow → session → turn, and
    /// returns the database plus the seeded turn's id for the projector to finalize.
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
