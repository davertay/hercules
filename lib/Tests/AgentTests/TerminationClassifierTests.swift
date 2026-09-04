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
            guard case .harnessFailed(let exitCode, let tail, _) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(exitCode == 2)
            #expect(tail == "boom")
        }
        #expect(recordedDuration == 42)
    }

    @Test func nonZeroExitPrefersErrorResultTextOverStderr() throws {
        do {
            try TerminationClassifier().classify(
                status: .exited(1),
                sessionId: sessionId,
                errorResultText: "You've hit your session limit · resets 12:40am",
                stderrTail: "",
                durationMs: 0,
                recordFailure: { _ in }
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .harnessFailed(_, let tail, _) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(tail == "You've hit your session limit · resets 12:40am")
        }
    }

    @Test func nonZeroExitFallsBackToStderrWhenErrorResultEmpty() throws {
        do {
            try TerminationClassifier().classify(
                status: .exited(1),
                sessionId: sessionId,
                errorResultText: "",
                stderrTail: "boom",
                durationMs: 0,
                recordFailure: { _ in }
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .harnessFailed(_, let tail, _) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(tail == "boom")
        }
    }

    @Test func malformedLineWinsOverErrorResultText() throws {
        struct Dummy: Error {}
        do {
            try TerminationClassifier().classify(
                status: .exited(1),
                sessionId: sessionId,
                lastMalformedLine: (raw: "not json", error: Dummy()),
                errorResultText: "some result text",
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

    /// The reported reason rides on the failure as a value, and shows in the message alongside the
    /// Harness's own wording rather than in place of it.
    @Test func nonZeroExitCarriesTheReportedStopFailureReason() throws {
        do {
            try TerminationClassifier().classify(
                status: .exited(1),
                sessionId: sessionId,
                errorResultText: "You've hit your session limit · resets 12:40am",
                stopFailureReason: "rate_limit",
                stderrTail: "",
                durationMs: 0,
                recordFailure: { _ in }
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .harnessFailed(_, let tail, let reason) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(reason == "rate_limit")
            #expect(tail == "You've hit your session limit · resets 12:40am")
            #expect(err.localizedDescription
                == "Harness failed code=1 (rate_limit): You've hit your session limit · resets 12:40am")
        }
    }

    /// No reason reported — the hook didn't fire, or this build's Harness has no such event — and the
    /// failure is byte for byte the one classification produced before the hook existed.
    @Test func noReportedReasonLeavesTheFailureUnchanged() throws {
        do {
            try TerminationClassifier().classify(
                status: .exited(1),
                sessionId: sessionId,
                stopFailureReason: nil,
                stderrTail: "boom",
                durationMs: 0,
                recordFailure: { _ in }
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let tail, let reason) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(reason == nil)
            #expect(exitCode == 1)
            #expect(tail == "boom")
            #expect(err.localizedDescription == "Harness failed code=1: boom")
        }
    }

    /// A reason can't rescue a stream we couldn't parse: the malformed line is still the failure worth
    /// reporting, since it points at the bug rather than at the API.
    @Test func malformedLineWinsOverTheReportedReason() throws {
        struct Dummy: Error {}
        do {
            try TerminationClassifier().classify(
                status: .exited(1),
                sessionId: sessionId,
                lastMalformedLine: (raw: "not json", error: Dummy()),
                stopFailureReason: "rate_limit",
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
