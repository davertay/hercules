import Dependencies
import Foundation
import Subprocess
import Transcript

struct HarnessRunner {
    @Dependency(\.date.now) var now
    @Dependency(\.harnessTeardownGrace) var teardownGrace
    let binaryURL: URL

    func run(request: SendRequest, writer: TranscriptWriter) async throws {
        let session = request.session
        let startedAt = now

        do {
            try writer.write(.turnStarted(.init(
                userPrompt: request.prompt,
                attachedFiles: [],
                startedAt: startedAt
            )))
        } catch {
            throw AgentError.transcriptIOFailed(session.dataDir, underlying: error)
        }

        let args = Harness.renderArgs(
            binary: binaryURL,
            operation: .resume,
            worktree: session.worktree,
            mode: session.mode,
            inputs: nil,
            sessionId: session.id
        )

        let process = SubProcess(
            executable: binaryURL,
            arguments: args,
            workingDirectory: session.worktree,
            teardownGrace: teardownGrace
        )

        let outcome: SubProcess.Outcome
        do {
            let promptString = Harness.renderPrompt(prompt: request.prompt, inputs: nil)
            outcome = try await process.run(input: promptString)
        } catch {
            throw AgentError.harnessIOFailed(underlying: error)
        }

        let endedAt = now
        let durationMs = Int(endedAt.timeIntervalSince(startedAt) * 1000)
        let stderrTail = outcome.stderrTail

        for chunk in outcome.stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            do {
                try writer.writeLine(Data(chunk))
            } catch {
                throw AgentError.transcriptIOFailed(session.dataDir, underlying: error)
            }
        }

        switch outcome.terminationStatus {
        case .exited(let code) where code == 0:
            do {
                try writer.write(.turnEnded(.init(endedAt: endedAt, durationMs: durationMs)))
            } catch {
                throw AgentError.transcriptIOFailed(session.dataDir, underlying: error)
            }

        case .exited(let code):
            // "No conversation found with session ID:" is the stable harness prefix
            // for an unknown session; it's narrow enough to not misclassify other failures.
            if stderrTail.contains("No conversation found with session ID:") {
                do {
                    try writer.write(.turnFailed(.init(
                        endedAt: endedAt, durationMs: durationMs,
                        errorKind: "sessionNotFound", errorMessage: stderrTail
                    )))
                } catch {}
                throw AgentError.sessionNotFound(id: session.id)
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

    func run(request: StartRequest, sessionId: Session.ID, writer: TranscriptWriter) async throws {
        let startedAt = now

        do {
            try writer.write(.sessionStarted(.init(
                sessionId: sessionId,
                worktree: request.worktree,
                mode: request.mode,
                attachedFiles: request.inputs?.relativePaths ?? [],
                startedAt: startedAt
            )))
            try writer.write(.turnStarted(.init(
                userPrompt: request.prompt,
                attachedFiles: request.inputs?.relativePaths ?? [],
                startedAt: startedAt
            )))
        } catch {
            throw AgentError.transcriptIOFailed(request.storageRoot, underlying: error)
        }

        let args = Harness.renderArgs(
            binary: binaryURL,
            operation: .start,
            worktree: request.worktree,
            mode: request.mode,
            inputs: request.inputs,
            sessionId: sessionId
        )

        let process = SubProcess(
            executable: binaryURL,
            arguments: args,
            workingDirectory: request.worktree,
            teardownGrace: teardownGrace
        )

        let outcome: SubProcess.Outcome
        do {
            let promptString = Harness.renderPrompt(prompt: request.prompt, inputs: request.inputs)
            outcome = try await process.run(input: promptString)
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw cancelled(startedAt: startedAt, writer: writer)
            }
            throw AgentError.harnessIOFailed(underlying: error)
        }

        // swift-subprocess kills the child on cancellation, so the run returns a
        // `.signaled` status rather than throwing; check the task to tell a
        // cancellation apart from a genuine crash.
        if Task.isCancelled {
            throw cancelled(startedAt: startedAt, writer: writer)
        }

        let endedAt = now
        let durationMs = Int(endedAt.timeIntervalSince(startedAt) * 1000)
        let stderrTail = outcome.stderrTail

        var lastMalformedLine: (raw: String, error: any Error)?
        for line in StreamParser().parse(outcome.stdout) {
            switch line {
            case .wellFormed(let data):
                do {
                    try writer.writeLine(data)
                } catch {
                    throw AgentError.transcriptIOFailed(request.storageRoot, underlying: error)
                }
            case .malformed(let raw, let error):
                lastMalformedLine = (raw: raw, error: error)
            }
        }

        try TerminationClassifier().classify(
            status: outcome.terminationStatus,
            lastMalformedLine: lastMalformedLine,
            stderrTail: stderrTail,
            endedAt: endedAt,
            durationMs: durationMs,
            writer: writer,
            storageRoot: request.storageRoot
        )
    }

    /// Records a cancelled turn in the transcript and returns the error to throw.
    private func cancelled(startedAt: Date, writer: TranscriptWriter) -> AgentError {
        let endedAt = now
        let durationMs = Int(endedAt.timeIntervalSince(startedAt) * 1000)
        try? writer.write(.turnFailed(.init(
            endedAt: endedAt, durationMs: durationMs,
            errorKind: "cancelled", errorMessage: ""
        )))
        return AgentError.cancelled
    }
}
