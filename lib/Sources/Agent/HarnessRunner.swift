import Dependencies
import Foundation

struct HarnessRunner {
    @Dependency(\.date.now) var now
    let binaryURL: URL

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

        let process = SubProcess(executable: binaryURL, arguments: args, workingDirectory: request.worktree)
        do {
            try process.run()
        } catch {
            throw AgentError.harnessNotFound(triedPath: binaryURL)
        }

        let outData: Data
        let errData: Data
        do {
            let promptData = Harness.renderPrompt(prompt: request.prompt, inputs: request.inputs)
            try process.write(string: promptData, close: true)
            (outData, errData) = try await process.waitUntilExit()
        } catch {
            throw AgentError.harnessIOFailed(underlying: error)
        }

        let endedAt = now
        let durationMs = Int(endedAt.timeIntervalSince(startedAt) * 1000)
        let stderrTail = String(data: errData.suffix(65536), encoding: .utf8) ?? ""

        for chunk in outData.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            do {
                try writer.writeLine(Data(chunk))
            } catch {
                throw AgentError.transcriptIOFailed(request.storageRoot, underlying: error)
            }
        }

        switch process.terminationReason {
        case .exit where process.terminationStatus == 0:
            do {
                try writer.write(.turnEnded(.init(endedAt: endedAt, durationMs: durationMs)))
            } catch {
                throw AgentError.transcriptIOFailed(request.storageRoot, underlying: error)
            }

        case .exit:
            do {
                try writer.write(.turnFailed(.init(
                    endedAt: endedAt, durationMs: durationMs,
                    errorKind: "harnessFailed", errorMessage: stderrTail
                )))
            } catch {}
            throw AgentError.harnessFailed(exitCode: process.terminationStatus, stderrTail: stderrTail)

        case .uncaughtSignal:
            do {
                try writer.write(.turnFailed(.init(
                    endedAt: endedAt, durationMs: durationMs,
                    errorKind: "harnessCrashed",
                    errorMessage: "Terminated by signal \(process.terminationStatus)"
                )))
            } catch {}
            throw AgentError.harnessCrashed(signal: process.terminationStatus, stderrTail: stderrTail)

        @unknown default:
            throw AgentError.harnessFailed(exitCode: process.terminationStatus, stderrTail: stderrTail)
        }
    }
}
