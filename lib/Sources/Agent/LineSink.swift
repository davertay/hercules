import Foundation
import Store

/// Bridges the Harness's live stdout into the Store's `TextProjector` for one Turn, and notes the
/// last non-JSON line so the `TerminationClassifier` can surface a `malformedStream` error when the
/// Harness also exits non-zero. The projector silently ignores malformed lines, so the tracking is
/// kept here rather than in the projector.
///
/// `@unchecked Sendable`: every access is serialized through the `OSAllocatedUnfairLock` the runner
/// wraps it in, and the only writer (the stdout drain) has finished before the runner reads back.
final class LineSink: @unchecked Sendable {
    private let projector: TextProjector
    private(set) var lastMalformedLine: (raw: String, error: any Error)?

    init(projector: TextProjector) {
        self.projector = projector
    }

    func ingest(_ line: Data) {
        do {
            _ = try JSONSerialization.jsonObject(with: line)
        } catch {
            let raw = String(data: line, encoding: .utf8) ?? "<non-UTF8 data>"
            lastMalformedLine = (raw: raw, error: error)
        }
        projector.ingest(line)
    }

    func recordFailure(durationMs: Int?) {
        projector.recordFailure(durationMs: durationMs)
    }
}
