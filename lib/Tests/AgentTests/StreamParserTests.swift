import Foundation
import Testing

@testable import Agent

@Suite("StreamParser")
struct StreamParserTests {
    let parser = StreamParser()

    @Test func wellFormedLineReturnsData() {
        let raw = #"{"type":"text","text":"hello"}"#
        let data = Data(raw.utf8)
        let lines = parser.parse(data)
        #expect(lines.count == 1)
        if case .wellFormed(let d) = lines[0] {
            #expect(d == data)
        } else {
            Issue.record("Expected .wellFormed, got \(lines[0])")
        }
    }

    @Test func malformedLineDoesNotAbortStream() {
        let input = "not valid json\n" + #"{"type":"text","text":"hello"}"# + "\n"
        let lines = parser.parse(Data(input.utf8))
        #expect(lines.count == 2)
        if case .malformed(let raw, _) = lines[0] {
            #expect(raw == "not valid json")
        } else {
            Issue.record("Expected .malformed first line, got \(lines[0])")
        }
        if case .wellFormed = lines[1] {} else {
            Issue.record("Expected .wellFormed second line, got \(lines[1])")
        }
    }

    @Test func framingLineIsWellFormed() {
        let raw = #"{"type":"hercules.turn.started","userPrompt":"hi","attachedFiles":[],"startedAt":"2026-01-01T00:00:00.000Z"}"#
        let lines = parser.parse(Data(raw.utf8))
        #expect(lines.count == 1)
        if case .wellFormed = lines[0] {} else {
            Issue.record("Framing line should be .wellFormed, got \(lines[0])")
        }
    }

    @Test func passthroughLineIsWellFormed() {
        let raw = #"{"type":"assistant","message":{"role":"assistant","content":[]}}"#
        let lines = parser.parse(Data(raw.utf8))
        #expect(lines.count == 1)
        if case .wellFormed = lines[0] {} else {
            Issue.record("Passthrough line should be .wellFormed, got \(lines[0])")
        }
    }

    @Test func emptyLinesAreOmitted() {
        let input = "\n\n" + #"{"type":"text"}"# + "\n\n"
        let lines = parser.parse(Data(input.utf8))
        #expect(lines.count == 1)
    }

    @Test func malformedLineExposesRawString() {
        let input = "{{ bad json }}\n"
        let lines = parser.parse(Data(input.utf8))
        #expect(lines.count == 1)
        if case .malformed(let raw, _) = lines[0] {
            #expect(raw == "{{ bad json }}")
        } else {
            Issue.record("Expected .malformed, got \(lines[0])")
        }
    }
}
