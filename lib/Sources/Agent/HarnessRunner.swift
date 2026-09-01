import Dependencies
import Foundation
import os
import SQLiteData
import Store
import Subprocess

struct HarnessRunner {
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid
    @Dependency(\.harnessTeardownGrace) var teardownGrace
    let binaryURL: URL
    /// Extra CLI arguments from the fresh `AppConfig`, appended after every generated argument.
    var extraArguments: [ExtraArgument] = []

    func run(request: SendRequest) async throws {
        let session = request.session
        try await runTurn(
            database: request.database,
            sessionId: session.id,
            prompt: request.prompt,
            operation: .resume,
            configuration: Harness.SessionConfiguration(
                session: session,
                mcpServers: request.mcpServers
            ),
            inputs: request.inputs
        )
    }

    func run(request: StartRequest, sessionId: Session.ID) async throws {
        do {
            try recordSessionStart(
                in: request.database,
                sessionID: sessionId.rawValue,
                workflowID: request.workflowID,
                worktreePath: request.worktree.path,
                mode: request.mode,
                kind: request.kind,
                issueNumber: request.issueNumber,
                at: now
            )
        } catch {
            throw AgentError.storeWriteFailed(underlying: error)
        }

        try await runTurn(
            database: request.database,
            sessionId: sessionId,
            prompt: request.prompt,
            operation: .start,
            configuration: Harness.SessionConfiguration(request: request),
            inputs: request.inputs
        )
    }

    /// Runs a single Turn: inserts its `turn` row, spawns the Harness, projects its stdout into the
    /// Store live, and classifies the termination — flagging the row and throwing on failure.
    private func runTurn(
        database: any DatabaseWriter,
        sessionId: Session.ID,
        prompt: String,
        operation: Harness.Operation,
        configuration: Harness.SessionConfiguration,
        inputs: InputBundle?
    ) async throws {
        let startedAt = now
        let turnID = uuid()

        do {
            try recordTurnStart(
                in: database,
                turnID: turnID,
                sessionID: sessionId.rawValue,
                userPrompt: prompt,
                at: startedAt
            )
        } catch {
            throw AgentError.storeWriteFailed(underlying: error)
        }

        let sink = OSAllocatedUnfairLock(
            initialState: LineSink(projector: StreamProjector(database: database, turnID: turnID))
        )

        // Scratch dir for the `--mcp-config` JSON; re-written each Turn so a resume re-passes the
        // pinned servers (ADR 0001).
        let sessionDataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hercules-sessions", isDirectory: true)
            .appendingPathComponent(sessionId.rawValue.uuidString, isDirectory: true)

        let args = try Harness.renderArgs(
            binary: binaryURL,
            operation: operation,
            configuration: configuration,
            inputs: inputs,
            sessionDataDirectory: sessionDataDirectory,
            extraArguments: extraArguments,
            sessionId: sessionId
        )

        let process = SubProcess(
            executable: binaryURL,
            arguments: args,
            workingDirectory: configuration.worktree,
            teardownGrace: teardownGrace
        )

        let outcome: SubProcess.Outcome
        do {
            let promptString = Harness.renderPrompt(prompt: prompt, inputs: inputs)
            outcome = try await process.run(input: promptString) { line in
                // Translate the projector's signal into the realtime protocol's stdin control.
                switch sink.withLock({ $0.ingest(line) }) {
                case .none: return .none
                case .askedQuestion: return .interrupt
                case .completed: return .finishInput
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw cancelled(startedAt: startedAt, sink: sink)
            }
            throw AgentError.harnessIOFailed(underlying: error)
        }

        // Cancellation kills the child (a `.signaled` status, not a throw), so check the task to tell
        // it apart from a genuine crash.
        if Task.isCancelled {
            throw cancelled(startedAt: startedAt, sink: sink)
        }

        // A paused run is a deliberate stop awaiting a question's answer — already projected, nothing
        // to classify or flag.
        if outcome.paused { return }

        let durationMs = Int(now.timeIntervalSince(startedAt) * 1000)

        try TerminationClassifier().classify(
            status: outcome.terminationStatus,
            sessionId: sessionId,
            lastMalformedLine: sink.withLock { $0.lastMalformedLine },
            errorResultText: sink.withLock { $0.lastErrorResult },
            stderrTail: outcome.stderrTail,
            durationMs: durationMs,
            recordFailure: { ms in sink.withLock { $0.recordFailure(durationMs: ms) } }
        )
    }

    /// Flags the Turn as failed and returns the error to throw on cancellation.
    private func cancelled(startedAt: Date, sink: OSAllocatedUnfairLock<LineSink>) -> AgentError {
        let durationMs = Int(now.timeIntervalSince(startedAt) * 1000)
        sink.withLock { $0.recordFailure(durationMs: durationMs) }
        return AgentError.cancelled
    }
}
