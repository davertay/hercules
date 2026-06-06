import Foundation
import Testing

@testable import Store

@Suite("TranscriptParser")
struct TranscriptParserTests {

    // A fixed date with a non-zero millisecond component to verify fractional-second precision.
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000.123)

    @Test func sessionStartedRoundTrips() throws {
        let sessionId = Session.ID(rawValue: UUID())
        let worktree = URL(fileURLWithPath: "/tmp/worktree")
        let event = HerculesEvent.sessionStarted(.init(
            sessionId: sessionId,
            worktree: worktree,
            mode: .write,
            attachedFiles: ["a.txt"],
            startedAt: Self.fixedDate
        ))
        let data = try JSONEncoder.transcript.encode(event)
        let line = try parseTranscriptLine(data)
        guard case .hercules(.sessionStarted(let decoded)) = line else {
            Issue.record("Expected .hercules(.sessionStarted), got \(line)")
            return
        }
        #expect(decoded.sessionId == sessionId)
        #expect(decoded.worktree == worktree)
        #expect(decoded.mode == .write)
        #expect(decoded.attachedFiles == ["a.txt"])
        #expect(abs(decoded.startedAt.timeIntervalSince(Self.fixedDate)) < 0.001)
    }

    @Test func turnStartedRoundTrips() throws {
        let event = HerculesEvent.turnStarted(.init(
            userPrompt: "hello",
            attachedFiles: ["b.txt"],
            startedAt: Self.fixedDate
        ))
        let data = try JSONEncoder.transcript.encode(event)
        let line = try parseTranscriptLine(data)
        guard case .hercules(.turnStarted(let decoded)) = line else {
            Issue.record("Expected .hercules(.turnStarted), got \(line)")
            return
        }
        #expect(decoded.userPrompt == "hello")
        #expect(decoded.attachedFiles == ["b.txt"])
        #expect(abs(decoded.startedAt.timeIntervalSince(Self.fixedDate)) < 0.001)
    }

    @Test func turnEndedRoundTrips() throws {
        let event = HerculesEvent.turnEnded(.init(endedAt: Self.fixedDate, durationMs: 42))
        let data = try JSONEncoder.transcript.encode(event)
        let line = try parseTranscriptLine(data)
        guard case .hercules(.turnEnded(let decoded)) = line else {
            Issue.record("Expected .hercules(.turnEnded), got \(line)")
            return
        }
        #expect(decoded.durationMs == 42)
        #expect(abs(decoded.endedAt.timeIntervalSince(Self.fixedDate)) < 0.001)
    }

    @Test func turnFailedRoundTrips() throws {
        let event = HerculesEvent.turnFailed(.init(
            endedAt: Self.fixedDate,
            durationMs: 99,
            errorKind: "crash",
            errorMessage: "unexpected exit"
        ))
        let data = try JSONEncoder.transcript.encode(event)
        let line = try parseTranscriptLine(data)
        guard case .hercules(.turnFailed(let decoded)) = line else {
            Issue.record("Expected .hercules(.turnFailed), got \(line)")
            return
        }
        #expect(decoded.durationMs == 99)
        #expect(decoded.errorKind == "crash")
        #expect(decoded.errorMessage == "unexpected exit")
        #expect(abs(decoded.endedAt.timeIntervalSince(Self.fixedDate)) < 0.001)
    }

    @Test func harnessPassthroughPreservesBytes() throws {
        let raw = #"{"type":"message_start","message":{"id":"msg_abc"}}"#
        let data = Data(raw.utf8)
        let line = try parseTranscriptLine(data)
        guard case .harness(rawJSON: let bytes) = line else {
            Issue.record("Expected .harness(rawJSON:), got \(line)")
            return
        }
        #expect(bytes == data)
    }
}
