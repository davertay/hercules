import Clocks
import Dependencies
import Foundation
import Testing

@testable import Agent

@Suite("Cancellation — integration")
struct CancellationTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Fixture not found: \(name)")
            throw CancellationError()
        }
        return url
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func cancelDuringSlowProcessThrowsCancelled() async throws {
        let fixture = try fixtureURL("slow.sh")
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            storageRoot: storageRoot
        )

        // SIGTERM alone stops slow.sh; the TestClock (never advanced) keeps the
        // 5s SIGKILL backstop suspended so it can't fire on the real clock
        // against a reused PID after the test ends.
        let testClock = TestClock()
        let task = Task {
            try await withDependencies {
                $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
                $0.continuousClock = testClock
            } operation: {
                let client = LiveAgentClient(binaryURL: fixture)
                return try await client.start(request)
            }
        }

        // Give slow.sh time to start before cancelling.
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected AgentError.cancelled to be thrown")
        } catch let err as AgentError {
            guard case .cancelled = err else {
                Issue.record("Expected .cancelled, got \(err)")
                return
            }
        }
    }

    @Test func cancelIgnoringSigtermFiresSigkillAndThrowsCancelled() async throws {
        let fixture = try fixtureURL("ignore-sigterm.sh")
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            storageRoot: storageRoot
        )

        let testClock = TestClock()
        let task = Task {
            try await withDependencies {
                $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
                $0.continuousClock = testClock
            } operation: {
                let client = LiveAgentClient(binaryURL: fixture)
                return try await client.start(request)
            }
        }

        // Give ignore-sigterm.sh time to start, then cancel.
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        // Allow the cancellation handler to create the SIGKILL Task and
        // have it suspended on testClock before we advance time.
        try await Task.sleep(nanoseconds: 100_000_000)
        await testClock.advance(by: .seconds(5))

        do {
            _ = try await task.value
            Issue.record("Expected AgentError.cancelled to be thrown")
        } catch let err as AgentError {
            guard case .cancelled = err else {
                Issue.record("Expected .cancelled, got \(err)")
                return
            }
        }
    }
}
