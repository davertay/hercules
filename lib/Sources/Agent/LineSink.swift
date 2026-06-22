import Foundation
import Store

/// Feeds the Harness's stdout into the `StreamProjector`, also noting the last non-JSON line so the
/// `TerminationClassifier` can surface a `malformedStream` error on a non-zero exit (the projector
/// silently ignores malformed lines).
///
/// `@unchecked Sendable`: every access is serialized through the runner's `OSAllocatedUnfairLock`.
final class LineSink: @unchecked Sendable {
    private let projector: StreamProjector
    private(set) var lastMalformedLine: (raw: String, error: any Error)?

    init(projector: StreamProjector) {
        self.projector = projector
    }

    @discardableResult
    func ingest(_ line: Data) -> StreamSignal {
        do {
            _ = try JSONSerialization.jsonObject(with: line)
        } catch {
            let raw = String(data: line, encoding: .utf8) ?? "<non-UTF8 data>"
            lastMalformedLine = (raw: raw, error: error)
        }
        return projector.ingest(line)
    }

    func recordFailure(durationMs: Int?) {
        projector.recordFailure(durationMs: durationMs)
    }
}
