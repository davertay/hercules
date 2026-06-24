import Foundation
import Store
import Subprocess

/// Maps a Harness termination status to an `AgentError`, flagging the Turn via `recordFailure` when it
/// fails before projecting a `result`. A clean exit is a no-op (the projector already finalized it).
struct TerminationClassifier {
    func classify(
        status: TerminationStatus,
        sessionId: Session.ID,
        lastMalformedLine: (raw: String, error: any Error)? = nil,
        errorResultText: String? = nil,
        stderrTail: String,
        durationMs: Int,
        recordFailure: (Int) -> Void
    ) throws {
        // The Harness writes its failure reason as an `is_error` result on stdout, then exits non-zero
        // with an empty stderr — so prefer that reason, falling back to the stderr tail.
        let detail = errorResultText.flatMap { $0.isEmpty ? nil : $0 } ?? stderrTail
        switch status {
        case .exited(let code) where code == 0:
            return
        case .exited(let code):
            recordFailure(durationMs)
            if let malformed = lastMalformedLine {
                throw AgentError.malformedStream(line: malformed.raw, underlying: malformed.error)
            }
            // The stable harness prefix for an unknown session.
            if stderrTail.contains("No conversation found with session ID:") {
                throw AgentError.sessionNotFound(id: sessionId)
            }
            throw AgentError.harnessFailed(exitCode: code, stderrTail: detail)
        case .signaled(let signal):
            recordFailure(durationMs)
            throw AgentError.harnessCrashed(signal: signal, stderrTail: detail)
        }
    }
}
