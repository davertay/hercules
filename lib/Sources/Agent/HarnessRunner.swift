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

    func run(request: SendRequest) async throws {
        let session = request.session
        try await runTurn(
            database: request.database,
            sessionId: session.id,
            prompt: request.prompt,
            operation: .resume,
            worktree: session.worktree,
            mode: session.mode,
            inputs: request.inputs,
            skillFiles: session.skillFiles,
            addDirs: session.addDirs
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
            worktree: request.worktree,
            mode: request.mode,
            inputs: request.inputs,
            skillFiles: request.skillFiles,
            addDirs: request.addDirs
        )
    }

    /// Runs a single Turn: inserts its `turn` row, spawns the Harness, projects its stdout into the
    /// Store live, and classifies the termination — flagging the row and throwing on failure.
    private func runTurn(
        database: any DatabaseWriter,
        sessionId: Session.ID,
        prompt: String,
        operation: Harness.Operation,
        worktree: URL,
        mode: AgentMode,
        inputs: InputBundle?,
        skillFiles: [URL],
        addDirs: [URL]
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

        let args = Harness.renderArgs(
            binary: binaryURL,
            operation: operation,
            worktree: worktree,
            mode: mode,
            inputs: inputs,
            skillFiles: skillFiles,
            addDirs: addDirs,
            sessionId: sessionId
        )

        let process = SubProcess(
            executable: binaryURL,
            arguments: args,
            workingDirectory: worktree,
            teardownGrace: teardownGrace
        )

        let outcome: SubProcess.Outcome
        do {
            let promptString = Harness.renderPrompt(prompt: prompt, inputs: inputs)
            outcome = try await process.run(input: promptString) { line in
                // Project the line, then translate the projector's signal into the stdin control the
                // realtime protocol needs: interrupt on a question, close stdin once the Turn ends.
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

        // swift-subprocess kills the child on cancellation, so the run returns a
        // `.signaled` status rather than throwing; check the task to tell a
        // cancellation apart from a genuine crash.
        if Task.isCancelled {
            throw cancelled(startedAt: startedAt, sink: sink)
        }

        // A paused run is a deliberate stop: we interrupted the Turn to await a question's answer.
        // The Turn is already projected (with the question card and a non-error result), and the
        // user's selection resumes the Session — so there's no exit to classify or failure to flag.
        if outcome.paused { return }

        let durationMs = Int(now.timeIntervalSince(startedAt) * 1000)

        try TerminationClassifier().classify(
            status: outcome.terminationStatus,
            sessionId: sessionId,
            lastMalformedLine: sink.withLock { $0.lastMalformedLine },
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
