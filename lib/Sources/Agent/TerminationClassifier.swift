import Foundation
import Store
import Subprocess

/// Maps a Harness's termination status to an `AgentError` on failure, and flags the Turn's row via
/// `recordFailure` when the Harness fails before — or instead of — projecting a `result` event.
/// A clean exit is a no-op: the live projector already finalized the Turn from its `result` event.
/// Cancellation is detected by the caller (via `Task`); the SIGTERM → SIGKILL escalation lives in
/// `SubProcess`'s teardown sequence.
struct TerminationClassifier {
    func classify(
        status: TerminationStatus,
        sessionId: Session.ID,
        lastMalformedLine: (raw: String, error: any Error)? = nil,
        stderrTail: String,
        durationMs: Int,
        recordFailure: (Int) -> Void
    ) throws {
        switch status {
        case .exited(let code) where code == 0:
            return
        case .exited(let code):
            recordFailure(durationMs)
            if let malformed = lastMalformedLine {
                throw AgentError.malformedStream(line: malformed.raw, underlying: malformed.error)
            }
            // "No conversation found with session ID:" is the stable harness prefix for an unknown
            // session; it's narrow enough to not misclassify other failures.
            if stderrTail.contains("No conversation found with session ID:") {
                throw AgentError.sessionNotFound(id: sessionId)
            }
            throw AgentError.harnessFailed(exitCode: code, stderrTail: stderrTail)
        case .signaled(let signal):
            recordFailure(durationMs)
            throw AgentError.harnessCrashed(signal: signal, stderrTail: stderrTail)
        }
    }
}
