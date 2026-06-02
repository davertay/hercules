import Clocks
import Dependencies
import Foundation
import Testing

@testable import Agent

@Suite("CancellationHandler — unit")
struct CancellationHandlerTests {
    // A pid_t unlikely to be a running process. Darwin.kill to a missing pid
    // returns ESRCH, which is harmless — we only care about timing, not the kill.
    private let fakePid: Int32 = 99999

    @Test func cancelFlipsWeCancelled() async throws {
        let handler = CancellationHandler()
        await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let task = Task {
                try await handler.withCancellation(processIdentifier: fakePid) {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            await Task.yield()
            task.cancel()
            _ = try? await task.value
        }
        #expect(handler.weCancelled)
    }

    @Test func sigkillScheduledWithFiveSecondDelay() async throws {
        let testClock = TestClock()
        let handler = CancellationHandler()

        // Run withCancellation inside an async withDependencies so that
        // `let capturedClock = clock` resolves to testClock.
        let innerTask = Task {
            await withDependencies {
                $0.continuousClock = testClock
            } operation: {
                let task = Task {
                    try await handler.withCancellation(processIdentifier: fakePid) {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
                await Task.yield()
                task.cancel()
                _ = try? await task.value
            }
        }

        // Give the cancellation handler a moment to create the SIGKILL Task
        // and have it suspended on testClock before we advance time.
        try await Task.sleep(nanoseconds: 50_000_000)

        // At 4 s the SIGKILL sleep (5 s) has not yet elapsed.
        await testClock.advance(by: .seconds(4))
        // At 5 s it elapses and SIGKILL is sent (to fakePid — harmless).
        await testClock.advance(by: .seconds(1))

        await innerTask.value
        #expect(handler.weCancelled)
    }

    @Test func signalExitWithWeCancelledFalseIsHarnessCrashed() throws {
        let handler = CancellationHandler()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = try TranscriptWriter(url: tempDir.appendingPathComponent("t.jsonl"))

        do {
            try handler.classifyTermination(
                reason: .uncaughtSignal,
                status: 15,
                stderrTail: "",
                endedAt: Date(),
                durationMs: 0,
                writer: writer,
                storageRoot: tempDir
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .harnessCrashed(let signal, _) = err else {
                Issue.record("Expected .harnessCrashed, got \(err)")
                return
            }
            #expect(signal == 15)
        }
    }

    @Test func signalExitWithWeCancelledTrueIsCancelled() async throws {
        let handler = CancellationHandler()

        await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let task = Task {
                try await handler.withCancellation(processIdentifier: fakePid) {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            await Task.yield()
            task.cancel()
            _ = try? await task.value
        }
        #expect(handler.weCancelled)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = try TranscriptWriter(url: tempDir.appendingPathComponent("t.jsonl"))

        do {
            try handler.classifyTermination(
                reason: .uncaughtSignal,
                status: 9,
                stderrTail: "",
                endedAt: Date(),
                durationMs: 0,
                writer: writer,
                storageRoot: tempDir
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .cancelled = err else {
                Issue.record("Expected .cancelled, got \(err)")
                return
            }
        }
    }
}
