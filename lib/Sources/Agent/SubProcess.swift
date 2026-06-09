import Darwin
import Foundation
import os
import Subprocess
import System

/// What the stdout drain asks `SubProcess` to write back on the Harness's stdin. Decided by the
/// caller from each projected line: keep going, interrupt the Turn (the agent asked a question), or
/// close stdin because the Turn finished.
enum HarnessInput: Sendable {
    case none
    case interrupt
    case finishInput
}

/// Spawns a Harness subprocess via swift-subprocess and drives its realtime stream-json protocol:
/// sends the prompt as a `user` message, drains stdout in full and stderr capped to a 64 KB tail,
/// and writes control messages back as the caller directs — an `interrupt` control_request to pause
/// on a question, and a stdin close to end the Turn. Reports the termination status.
///
/// Cancellation is owned by swift-subprocess: the configured teardown sequence
/// sends `SIGTERM`, waits `teardownGrace`, then sends `SIGKILL` to the harness.
/// There is no bespoke fd/SIGPIPE/EPIPE/drain/termination plumbing here anymore
/// — the library handles non-blocking stdio drain and child reaping under
/// async/await. (As of swift-subprocess 0.5 the library also cancels its stdout
/// drain when the child exits, so an orphaned grandchild that inherits the pipe
/// can't wedge the read past the harness's own exit — we no longer reap the
/// process group ourselves.)
struct SubProcess {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    /// How long the child is given to exit on `SIGTERM` before `SIGKILL`.
    let teardownGrace: Duration

    /// Sets `SIGPIPE` to `SIG_IGN` exactly once, process-wide. A `static let` is initialized lazily
    /// and at-most-once under the runtime's thread-safe guarantee, so reading it before the first run
    /// installs the disposition without races or repeated work.
    private static let ensureSIGPIPEIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    struct Outcome {
        let stderrTail: String
        let terminationStatus: TerminationStatus
        /// True when the Turn was interrupted to await a question's answer, so the caller can treat
        /// the run as a deliberate pause rather than classify its exit as a failure.
        let paused: Bool
    }

    /// Runs the Harness, delivering each complete NDJSON line of stdout to `onStdoutLine` as it
    /// arrives (live streaming, per ADR 0003) rather than buffering the whole output. `onStdoutLine`
    /// is invoked serially from the stdout drain and returns the control message to write back:
    /// `.interrupt` to pause on a question, `.finishInput` once the Turn's result lands (so the
    /// Harness exits). Callers that mutate shared state from it must guard that state.
    func run(input: String, onStdoutLine: @escaping @Sendable (Data) -> HarnessInput) async throws -> Outcome {
        // swift-subprocess 0.5's Unix write path issues raw `write(2)` calls, which raise SIGPIPE when
        // the child has closed its stdin read-end (e.g. a harness that exits before consuming the
        // prompt). Ignore SIGPIPE process-wide so those writes fail with `EPIPE` — surfaced as a
        // `SubprocessError` we already handle — instead of terminating us. (0.4's DispatchIO path
        // didn't raise the signal.)
        Self.ensureSIGPIPEIgnored

        var platformOptions = PlatformOptions()
        // SIGTERM, then SIGKILL after the grace period. swift-subprocess always
        // appends a final SIGKILL step, so this gives us the SIGTERM → grace →
        // SIGKILL escalation on task cancellation (and on body failure).
        platformOptions.teardownSequence = [
            .gracefulShutDown(allowedDurationToNextStep: teardownGrace)
        ]

        let paused = OSAllocatedUnfairLock(initialState: false)
        let result = try await Subprocess.run(
            .path(FilePath(executable.path)),
            arguments: Arguments(arguments),
            environment: .inherit,
            workingDirectory: FilePath(workingDirectory.path),
            platformOptions: platformOptions,
            input: .inputWriter,
            output: .sequence,
            error: .sequence
        ) { execution in
            let inputWriter = execution.standardInputWriter
            // Drain stderr concurrently so a payload larger than the pipe buffer can't wedge us.
            async let errTail = Self.collectTail(execution.standardError)

            // Send the prompt as the first stream-json user message. Unlike text input we keep
            // stdin open afterwards so we can interrupt the Turn mid-flight if it asks a question.
            do {
                _ = try await inputWriter.write(Self.userMessage(input))
            } catch let error as SubprocessError where error.isBrokenPipe {
                // A harness that exits before consuming the prompt closes its
                // stdin read-end, so our write fails with EPIPE. That isn't a
                // delivery fault to surface — the child's exit status and
                // stderr are the real signal, so swallow it and let
                // termination classification report the outcome.
            }

            // Drain stdout on this task, acting on each line's control message inline so the
            // writes stay serialized with the prompt write (one stdin user, no data race).
            try await Self.streamLines(execution.standardOutput) { line in
                switch onStdoutLine(line) {
                case .none:
                    break
                case .interrupt:
                    paused.withLock { $0 = true }
                    _ = try? await inputWriter.write(Self.interruptRequest())
                case .finishInput:
                    // The Turn is done; closing stdin lets the realtime-input Harness exit
                    // (it would otherwise keep waiting for the next message).
                    try? await inputWriter.finish()
                }
            }

            return try await errTail
        }

        return Outcome(
            stderrTail: result.closureOutput,
            terminationStatus: result.terminationStatus,
            paused: paused.withLock { $0 }
        )
    }

    /// The prompt wrapped as a stream-json `user` message, newline-terminated for the NDJSON channel.
    private static func userMessage(_ prompt: String) -> String {
        jsonLine(["type": "user", "message": ["role": "user", "content": prompt]])
    }

    /// An `interrupt` control_request that stops the current Turn. The `request_id` only needs to be
    /// unique within the run; the Harness echoes it back on the matching `control_response`.
    private static func interruptRequest() -> String {
        jsonLine([
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "interrupt"],
        ])
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string + "\n"
    }

    /// Splits a stream into NDJSON lines across buffer boundaries, delivering each non-empty line
    /// (newline stripped) to `onLine`. A trailing line without a final newline is delivered at EOF.
    private static func streamLines(
        _ sequence: SubprocessOutputSequence,
        onLine: (Data) async throws -> Void
    ) async throws {
        var buffer = Data()
        for try await chunk in sequence {
            chunk.withUnsafeBytes { buffer.append(contentsOf: $0) }
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { try await onLine(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { try await onLine(Data(buffer)) }
    }

    /// Accumulates a stream's output, keeping only the trailing 64 KB.
    private static func collectTail(_ sequence: SubprocessOutputSequence) async throws -> String {
        var collector = StderrCollector()
        for try await buffer in sequence {
            buffer.withUnsafeBytes { collector.append(Data($0)) }
        }
        return collector.tail
    }
}

private extension SubprocessError {
    var isBrokenPipe: Bool {
        underlyingError?.rawValue == EPIPE
    }
}
