import Darwin
import Foundation
import Subprocess
import System

/// Spawns a Harness subprocess via swift-subprocess: writes the prompt to stdin
/// then closes it, drains stdout in full and stderr capped to a 64 KB tail, and
/// reports the termination status.
///
/// Cancellation is owned by swift-subprocess: the configured teardown sequence
/// sends `SIGTERM`, waits `teardownGrace`, then sends `SIGKILL` to the harness.
/// There is no bespoke fd/SIGPIPE/EPIPE/drain/termination plumbing here anymore
/// — the library handles non-blocking stdio drain and child reaping under
/// async/await.
struct SubProcess {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    /// How long the child is given to exit on `SIGTERM` before `SIGKILL`.
    let teardownGrace: Duration

    struct Outcome {
        let stderrTail: String
        let terminationStatus: TerminationStatus
    }

    /// Runs the Harness, delivering each complete NDJSON line of stdout to `onStdoutLine` as it
    /// arrives (live streaming, per ADR 0003) rather than buffering the whole output. `onStdoutLine`
    /// is invoked serially from the stdout drain task; callers that mutate shared state from it must
    /// guard that state.
    func run(input: String, onStdoutLine: @escaping @Sendable (Data) -> Void) async throws -> Outcome {
        var platformOptions = PlatformOptions()
        // SIGTERM, then SIGKILL after the grace period. swift-subprocess always
        // appends a final SIGKILL step, so this gives us the SIGTERM → grace →
        // SIGKILL escalation on task cancellation (and on body failure).
        platformOptions.teardownSequence = [
            .gracefulShutDown(allowedDurationToNextStep: teardownGrace)
        ]
        // Put the harness in its own process group so we can signal the whole
        // group (harness + any descendants) without touching our own process.
        // See the orphan-pipe handling in the cancellation handler below.
        platformOptions.processGroupID = 0

        let grace = teardownGrace
        let outcome = try await Subprocess.run(
            .path(FilePath(executable.path)),
            arguments: Arguments(arguments),
            environment: .inherit,
            workingDirectory: FilePath(workingDirectory.path),
            platformOptions: platformOptions
        ) { execution, inputWriter, standardOutput, standardError in
            let pgid = execution.processIdentifier.value
            return try await withTaskCancellationHandler {
                // Drain both pipes concurrently so a payload larger than the pipe
                // buffer can't wedge the writer.
                async let outDone: Void = Self.streamLines(standardOutput, onLine: onStdoutLine)
                async let errTail = Self.collectTail(standardError)

                do {
                    _ = try await inputWriter.write(input)
                } catch let error as SubprocessError where error.isBrokenPipe {
                    // A harness that exits before consuming the prompt closes its
                    // stdin read-end, so our write fails with EPIPE. That isn't a
                    // delivery fault to surface — the child's exit status and
                    // stderr are the real signal, so swallow it and let
                    // termination classification report the outcome.
                }
                try? await inputWriter.finish()

                try await outDone
                return try await errTail
            } onCancel: {
                reapProcessGroup(pgid, after: grace)
            }
        }

        return Outcome(
            stderrTail: outcome.value,
            terminationStatus: outcome.terminationStatus
        )
    }

    /// Splits a stream into NDJSON lines across buffer boundaries, delivering each non-empty line
    /// (newline stripped) to `onLine`. A trailing line without a final newline is delivered at EOF.
    private static func streamLines(
        _ sequence: AsyncBufferSequence,
        onLine: @Sendable (Data) -> Void
    ) async throws {
        var buffer = Data()
        for try await chunk in sequence {
            chunk.withUnsafeBytes { buffer.append(contentsOf: $0) }
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { onLine(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { onLine(Data(buffer)) }
    }

    /// Accumulates a stream's output, keeping only the trailing 64 KB.
    private static func collectTail(_ sequence: AsyncBufferSequence) async throws -> String {
        var collector = StderrCollector()
        for try await buffer in sequence {
            buffer.withUnsafeBytes { collector.append(Data($0)) }
        }
        return collector.tail
    }
}

/// On cancellation swift-subprocess escalates SIGTERM → grace → SIGKILL on the
/// harness pid. But a harness descendant that inherits and outlives the
/// stdout/stderr pipe (e.g. an orphaned background process) keeps the pipe's
/// write-end open, so our drain would never see EOF and the turn would hang
/// past the harness's own exit. After the same grace period, SIGKILL the whole
/// process group to reap any such orphan and let the drain reach EOF.
private func reapProcessGroup(_ pgid: pid_t, after grace: Duration) {
    guard pgid > 1 else { return }
    Task.detached {
        try? await Task.sleep(for: grace)
        // `kill(_, 0)` probes liveness; only escalate if the group is still
        // around, to narrow the window for signalling a recycled pgid.
        if Darwin.kill(-pgid, 0) == 0 {
            Darwin.kill(-pgid, SIGKILL)
        }
    }
}

private extension SubprocessError {
    var isBrokenPipe: Bool {
        underlyingError?.rawValue == EPIPE
    }
}
