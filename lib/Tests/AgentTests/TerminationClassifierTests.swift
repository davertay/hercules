import Foundation
import Subprocess
import Testing
import Store

@testable import Agent

@Suite("TerminationClassifier — unit")
struct TerminationClassifierTests {
    private let sessionId = Session.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    @Test func cleanExitDoesNotRecordFailure() throws {
        var recordedDuration: Int?
        try TerminationClassifier().classify(
            status: .exited(0),
            sessionId: sessionId,
            stderrTail: "",
            durationMs: 0,
            recordFailure: { recordedDuration = $0 }
        )
        #expect(recordedDuration == nil)
    }

    @Test func nonZeroExitThrowsHarnessFailedAndRecordsFailure() throws {
        var recordedDuration: Int?
        do {
            try TerminationClassifier().classify(
                status: .exited(2),
                sessionId: sessionId,
                stderrTail: "boom",
                durationMs: 42,
                recordFailure: { recordedDuration = $0 }
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let tail) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(exitCode == 2)
            #expect(tail == "boom")
        }
        #expect(recordedDuration == 42)
    }

    @Test func nonZeroExitWithMalformedLineThrowsMalformedStream() throws {
        struct Dummy: Error {}
        do {
            try TerminationClassifier().classify(
                status: .exited(1),
                sessionId: sessionId,
                lastMalformedLine: (raw: "not json", error: Dummy()),
                stderrTail: "",
                durationMs: 0,
                recordFailure: { _ in }
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .malformedStream(let line, _) = err else {
                Issue.record("Expected .malformedStream, got \(err)")
                return
            }
            #expect(line == "not json")
        }
    }

    @Test func sessionNotFoundStderrThrowsSessionNotFound() throws {
        do {
            try TerminationClassifier().classify(
                status: .exited(1),
                sessionId: sessionId,
                stderrTail: "No conversation found with session ID: abc",
                durationMs: 0,
                recordFailure: { _ in }
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .sessionNotFound(let id) = err else {
                Issue.record("Expected .sessionNotFound, got \(err)")
                return
            }
            #expect(id == sessionId)
        }
    }

    @Test func signalTerminationThrowsHarnessCrashed() throws {
        do {
            try TerminationClassifier().classify(
                status: .signaled(15),
                sessionId: sessionId,
                stderrTail: "",
                durationMs: 0,
                recordFailure: { _ in }
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .harnessCrashed(let signal, _) = err else {
                Issue.record("Expected .harnessCrashed, got \(err)")
                return
            }
            #expect(signal == 15)
        }
    }
}
