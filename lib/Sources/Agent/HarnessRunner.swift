import Foundation

struct HarnessRunner {
    let binaryURL: URL

    func run(request: StartRequest, sessionId: Session.ID, writer: TranscriptWriter) async throws {
        let startedAt = Date()

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

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args
        process.currentDirectoryURL = request.worktree
        process.environment = ProcessInfo.processInfo.environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AgentError.harnessNotFound(triedPath: binaryURL)
        }

        let promptData = Harness.renderPrompt(prompt: request.prompt, inputs: request.inputs)
            .data(using: .utf8) ?? Data()
        stdinPipe.fileHandleForWriting.write(promptData)
        try? stdinPipe.fileHandleForWriting.close()

        let (outData, errData) = await drainPipes(stdout: stdoutPipe, stderr: stderrPipe)
        process.waitUntilExit()

        let endedAt = Date()
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

    private func drainPipes(stdout: Pipe, stderr: Pipe) async -> (Data, Data) {
        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading
        return await withTaskGroup(of: (Bool, Data).self) { group in
            group.addTask { (true, outHandle.readDataToEndOfFile()) }
            group.addTask { (false, errHandle.readDataToEndOfFile()) }
            var out = Data()
            var err = Data()
            for await (isOut, data) in group {
                if isOut { out = data } else { err = data }
            }
            return (out, err)
        }
    }
}
