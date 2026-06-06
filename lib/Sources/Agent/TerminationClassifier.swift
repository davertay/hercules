import Foundation
import Subprocess
import Store

/// Maps a Harness's termination status to a transcript event and, on failure,
/// an `AgentError`. Cancellation is detected by the caller (via `Task`); the
/// SIGTERM → SIGKILL escalation lives in `SubProcess`'s teardown sequence.
struct TerminationClassifier {
    func classify(
        status: TerminationStatus,
        lastMalformedLine: (raw: String, error: any Error)? = nil,
        stderrTail: String,
        endedAt: Date,
        durationMs: Int,
        writer: TranscriptWriter,
        storageRoot: URL
    ) throws {
        switch status {
        case .exited(let code) where code == 0:
            do {
                try writer.write(.turnEnded(.init(endedAt: endedAt, durationMs: durationMs)))
            } catch {
                throw AgentError.transcriptIOFailed(storageRoot, underlying: error)
            }
        case .exited(let code):
            if let malformed = lastMalformedLine {
                do {
                    try writer.write(.turnFailed(.init(
                        endedAt: endedAt, durationMs: durationMs,
                        errorKind: "malformedStream", errorMessage: malformed.raw
                    )))
                } catch {}
                throw AgentError.malformedStream(line: malformed.raw, underlying: malformed.error)
            }
            do {
                try writer.write(.turnFailed(.init(
                    endedAt: endedAt, durationMs: durationMs,
                    errorKind: "harnessFailed", errorMessage: stderrTail
                )))
            } catch {}
            throw AgentError.harnessFailed(exitCode: code, stderrTail: stderrTail)
        case .signaled(let signal):
            do {
                try writer.write(.turnFailed(.init(
                    endedAt: endedAt, durationMs: durationMs,
                    errorKind: "harnessCrashed",
                    errorMessage: "Terminated by signal \(signal)"
                )))
            } catch {}
            throw AgentError.harnessCrashed(signal: signal, stderrTail: stderrTail)
        }
    }
}
