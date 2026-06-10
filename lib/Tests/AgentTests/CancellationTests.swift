import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import Agent

@Suite(
    "Cancellation — integration",
    .dependency(\.uuid, .incrementing),
    .dependency(\.date, .constant(Date(timeIntervalSinceReferenceDate: 1_234_567_890)))
)
struct CancellationTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Fixture not found: \(name)")
            throw CancellationError()
        }
        return url
    }

    @Test func cancelDuringSlowProcessThrowsCancelled() async throws {
        let fixture = try fixtureURL("slow.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            database: database,
            workflowID: workflowID,
            kind: .design
        )

        // slow.sh exits on SIGTERM, so the teardown sequence reaps it well within
        // the grace period.
        let task = Task {
            try await withDependencies {
                $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
                $0.harnessTeardownGrace = .milliseconds(200)
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
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            database: database,
            workflowID: workflowID,
            kind: .design
        )

        // ignore-sigterm.sh traps SIGTERM, so the grace period elapses and the
        // teardown escalates to SIGKILL. Its orphaned `sleep` (which inherits the
        // stdout/stderr pipes) must also be reaped, otherwise the drain can't see
        // EOF and the turn hangs.
        let task = Task {
            try await withDependencies {
                $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
                $0.harnessTeardownGrace = .milliseconds(200)
            } operation: {
                let client = LiveAgentClient(binaryURL: fixture)
                return try await client.start(request)
            }
        }

        // Give ignore-sigterm.sh time to start, then cancel.
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
}
