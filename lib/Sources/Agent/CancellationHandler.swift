import Darwin
import Dependencies
import Foundation
import os

struct CancellationHandler: Sendable {
    @Dependency(\.continuousClock) var clock

    private let weCancelledFlag = OSAllocatedUnfairLock(initialState: false)

    var weCancelled: Bool {
        weCancelledFlag.withLock { $0 }
    }

    func withCancellation<T: Sendable>(
        processIdentifier: Int32,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let capturedClock = clock
        return try await withTaskCancellationHandler {
            try await operation()
        } onCancel: {
            weCancelledFlag.withLock { $0 = true }
            Darwin.kill(processIdentifier, SIGTERM)
            Task {
                try? await capturedClock.sleep(for: .seconds(5))
                Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }

    func classifyTermination(
        reason: Process.TerminationReason,
        status: Int32,
        stderrTail: String,
        endedAt: Date,
        durationMs: Int,
        writer: TranscriptWriter,
        storageRoot: URL
    ) throws {
        if weCancelled {
            try? writer.write(.turnFailed(.init(
                endedAt: endedAt, durationMs: durationMs,
                errorKind: "cancelled", errorMessage: ""
            )))
            throw AgentError.cancelled
        }
        switch reason {
        case .exit where status == 0:
            do {
                try writer.write(.turnEnded(.init(endedAt: endedAt, durationMs: durationMs)))
            } catch {
                throw AgentError.transcriptIOFailed(storageRoot, underlying: error)
            }
        case .exit:
            do {
                try writer.write(.turnFailed(.init(
                    endedAt: endedAt, durationMs: durationMs,
                    errorKind: "harnessFailed", errorMessage: stderrTail
                )))
            } catch {}
            throw AgentError.harnessFailed(exitCode: status, stderrTail: stderrTail)
        case .uncaughtSignal:
            do {
                try writer.write(.turnFailed(.init(
                    endedAt: endedAt, durationMs: durationMs,
                    errorKind: "harnessCrashed",
                    errorMessage: "Terminated by signal \(status)"
                )))
            } catch {}
            throw AgentError.harnessCrashed(signal: status, stderrTail: stderrTail)
        @unknown default:
            throw AgentError.harnessFailed(exitCode: status, stderrTail: stderrTail)
        }
    }
}
