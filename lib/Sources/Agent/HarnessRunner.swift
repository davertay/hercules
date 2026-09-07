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
            trustsRepositorySettings: request.trustsRepositorySettings,
            inputs: request.inputs,
            onQuestion: request.onQuestion
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
            trustsRepositorySettings: request.trustsRepositorySettings,
            inputs: request.inputs,
            onQuestion: request.onQuestion
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
        trustsRepositorySettings: Bool,
        inputs: InputBundle?,
        onQuestion: QuestionHandler?
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

        // Scratch dir for what this Turn generates for the Harness and its children to read back: the
        // `--mcp-config` servers, the `--settings` hook registration, and the question channel below.
        let scratch = Harness.TurnScratch(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("hercules-sessions", isDirectory: true)
                .appendingPathComponent(sessionId.rawValue.uuidString, isDirectory: true),
            turnID: turnID
        )
        // Both of this Turn's files are spent the moment the classification below has run: the Harness
        // read `--settings` at startup, and the drop-file has one reader. Deferred from here so every
        // exit — a cancellation, an I/O failure, a throw out of classification — leaves the directory
        // as it found it.
        defer { scratch.removeTurnFiles() }

        // A caller offering to answer is what makes the Turn attended, and an attended Turn is one that
        // can ask: the channel is opened in this Turn's scratch, the ``AttendedTurn`` bundle pointed at it
        // gives the Turn both the tool and the rules for using it, and every call announced there is put
        // to the caller. Without a caller to answer, none of it is attached — an unattended Turn that
        // blocked on a question would wait until it was torn down.
        var configuration = configuration
        var questions: Task<Void, any Error>?
        if let onQuestion {
            let channel = QuestionChannel(directory: scratch.questionChannelDirectory)
            AttendedTurn(channelDirectory: channel.directory).attach(to: &configuration)
            questions = Task { try await channel.serve(onQuestion) }
        }
        // Cancelled rather than awaited: the Turn is over either way, and whether a caller still holding
        // a question on screen ever returns is not something its outcome may wait on.
        defer { questions?.cancel() }

        let args = try Harness.renderArgs(
            binary: binaryURL,
            operation: operation,
            configuration: configuration,
            trustsRepositorySettings: trustsRepositorySettings,
            inputs: inputs,
            scratch: scratch,
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

        let durationMs = Int(now.timeIntervalSince(startedAt) * 1000)

        // The Harness's own account of why it stopped, left by the hook we registered for this Turn.
        // Absent for every Turn the hook didn't fire on, which classification then handles exactly as
        // it did before the hook existed.
        let stopFailureReason = StopFailureHook.reportedReason(dropFile: scratch.stopFailureDropFile)

        try TerminationClassifier().classify(
            status: outcome.terminationStatus,
            sessionId: sessionId,
            lastMalformedLine: sink.withLock { $0.lastMalformedLine },
            errorResultText: sink.withLock { $0.lastErrorResult },
            stopFailureReason: stopFailureReason,
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
