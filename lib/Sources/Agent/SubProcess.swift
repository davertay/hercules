import Darwin
import Foundation
import Subprocess
import System

/// The control message the stdout drain writes back on the Harness's stdin.
enum HarnessInput: Sendable {
    case none
    /// Stops the Turn in flight. The cancellation path's polite alternative to a signal — it lets the
    /// Harness unwind and write a complete transcript — and the primitive a taken-over Session will use
    /// to inject steering mid-Turn.
    case interrupt
    case finishInput
}

/// Spawns a Harness subprocess via swift-subprocess and drives its realtime stream-json protocol:
/// sends the prompt as a `user` message, drains stdout and a 64 KB stderr tail, and writes control
/// messages back as the caller directs. Cancellation/teardown (SIGTERM → grace → SIGKILL) and stdio
/// drain are owned by swift-subprocess; there is no bespoke fd/drain/reaping plumbing here.
struct SubProcess {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    /// How long the child is given to exit on `SIGTERM` before `SIGKILL`.
    let teardownGrace: Duration

    /// Sets `SIGPIPE` to `SIG_IGN` once, process-wide — a `static let` is initialized at-most-once.
    private static let ensureSIGPIPEIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Directories prepended to the child's `PATH`. A macOS app launched from Finder/Dock inherits
    /// launchd's minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), which omits Homebrew — so the
    /// agent's Bash tool can't find user-installed CLIs like `gh`. We add the common Homebrew/user
    /// bin dirs so those tools resolve. (The harness binary itself is resolved separately, by path.)
    static let pathAdditions = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]

    /// Prepends `additions` to the inherited `PATH`, dropping any already present so their existing
    /// position is preserved. Pure, so it's unit-testable without touching the process environment.
    static func augmentedPath(
        inherited: String?,
        additions: [String] = pathAdditions
    ) -> String {
        let existing = (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        let existingSet = Set(existing)
        let prefix = additions.filter { !existingSet.contains($0) }
        return (prefix + existing).joined(separator: ":")
    }

    /// The Harness's own idle timer on an MCP tool call. Measured on 2.1.260/261, the default aborts a
    /// silent `tools/call` at just over thirty minutes with an explicit abort message — and a blocking
    /// `ask_user` is silent for exactly as long as the user takes to answer. `0` disables it, which is
    /// both necessary and sufficient.
    ///
    /// No Hercules-side deadline replaces it. Any value would be arbitrary, and a question left
    /// unanswered is already visible to the user: the Turn is on screen and Stop is in the toolbar.
    static let mcpToolIdleTimeoutVariable = "CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"

    /// What the child's inherited environment is launched with on top of it. Pure, so the invocation
    /// can be asserted on without spawning anything.
    static func environmentOverrides(inherited path: String?) -> [String: String] {
        [
            "PATH": augmentedPath(inherited: path),
            mcpToolIdleTimeoutVariable: "0",
        ]
    }

    struct Outcome {
        let stderrTail: String
        let terminationStatus: TerminationStatus
    }

    /// Delivers each complete NDJSON stdout line to `onStdoutLine` as it arrives (live streaming, per
    /// ADR 0003). `onStdoutLine` is invoked serially and returns the control message to write back;
    /// callers that mutate shared state from it must guard it.
    func run(input: String, onStdoutLine: @escaping @Sendable (Data) -> HarnessInput) async throws -> Outcome {
        // swift-subprocess's raw `write(2)` path raises SIGPIPE when the child has closed its stdin
        // read-end (e.g. a harness that exits before consuming the prompt). Ignore it so those writes
        // fail with `EPIPE` — a `SubprocessError` we handle — instead of terminating us.
        Self.ensureSIGPIPEIgnored

        // swift-subprocess keys an environment by its own `Environment.Key`; converting here leaves the
        // overrides themselves a plain dictionary, which is what makes them assertable without spawning.
        let environment = Self.environmentOverrides(inherited: ProcessInfo.processInfo.environment["PATH"])
            .reduce(into: [Environment.Key: String?]()) { $0[Environment.Key(stringLiteral: $1.key)] = $1.value }

        var platformOptions = PlatformOptions()
        // swift-subprocess always appends a final SIGKILL, giving SIGTERM → grace → SIGKILL.
        platformOptions.teardownSequence = [
            .gracefulShutDown(allowedDurationToNextStep: teardownGrace)
        ]

        let result = try await Subprocess.run(
            .path(FilePath(executable.path)),
            arguments: Arguments(arguments),
            environment: .inherit.updating(environment),
            workingDirectory: FilePath(workingDirectory.path),
            platformOptions: platformOptions,
            input: .inputWriter,
            output: .sequence,
            error: .sequence
        ) { execution in
            let inputWriter = execution.standardInputWriter
            // Drain stderr concurrently so a payload larger than the pipe buffer can't wedge us.
            async let errTail = Self.collectTail(execution.standardError)

            // Keep stdin open after the prompt: it's the Turn's control channel, and the only way to
            // reach a Harness that's already running.
            do {
                _ = try await inputWriter.write(Self.userMessage(input))
            } catch let error as SubprocessError where error.isBrokenPipe {
                // A harness that exits before consuming the prompt fails our write with EPIPE; its exit
                // status and stderr are the real signal, so swallow it.
            }

            // Act on each line's control inline so writes stay serialized with the prompt write.
            try await Self.streamLines(execution.standardOutput) { line in
                switch onStdoutLine(line) {
                case .none:
                    break
                case .interrupt:
                    _ = try? await inputWriter.write(Self.interruptRequest())
                case .finishInput:
                    // Closing stdin lets the realtime-input Harness exit instead of awaiting more input.
                    try? await inputWriter.finish()
                }
            }

            return try await errTail
        }

        return Outcome(
            stderrTail: result.closureResult,
            terminationStatus: result.terminationStatus
        )
    }

    private static func userMessage(_ prompt: String) -> String {
        jsonLine(["type": "user", "message": ["role": "user", "content": prompt]])
    }

    /// An `interrupt` control_request stopping the current Turn. The `request_id` need only be unique
    /// within the run; the Harness echoes it back on the matching `control_response`.
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

    /// Splits a stream into NDJSON lines across buffer boundaries. A trailing line without a final
    /// newline is delivered at EOF.
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
