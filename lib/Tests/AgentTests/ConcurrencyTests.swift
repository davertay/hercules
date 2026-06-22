import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import Agent

@Suite(
    "Concurrency — session overlap",
    .dependency(\.uuid, .incrementing),
    .dependency(\.date, .constant(Date(timeIntervalSinceReferenceDate: 1_234_567_890)))
)
struct ConcurrencyTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Fixture not found: \(name)")
            throw CancellationError()
        }
        return url
    }

    private func client(_ fixture: URL) -> LiveAgentClient {
        withDependencies {
            $0.date.now = Date(timeIntervalSinceReferenceDate: 1_234_567_890)
        } operation: {
            LiveAgentClient(binaryURL: fixture)
        }
    }

    @Test func sameSesssionOverlapRejectsSecond() async throws {
        let echoFixture = try fixtureURL("echo-init.sh")
        let slowFixture = try fixtureURL("slow.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await client(echoFixture).start(StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            database: database,
            workflowID: workflowID,
            kind: .design
        ))

        let slowClient = client(slowFixture)

        let firstTask = Task {
            try await slowClient.send(SendRequest(prompt: "first", session: session, database: database))
        }

        // Let slow.sh acquire the lock before the second send.
        try await Task.sleep(nanoseconds: 200_000_000)

        do {
            _ = try await slowClient.send(SendRequest(prompt: "second", session: session, database: database))
            Issue.record("Expected AgentError.sessionBusy to be thrown")
        } catch let err as AgentError {
            guard case .sessionBusy(let id) = err else {
                Issue.record("Expected .sessionBusy, got \(err)")
                firstTask.cancel()
                _ = try? await firstTask.value
                return
            }
            #expect(id == session.id)
        }

        firstTask.cancel()
        _ = try? await firstTask.value
    }

    @Test func differentSessionsProceedInParallel() async throws {
        let echoFixture = try fixtureURL("echo-init.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = client(echoFixture)

        let session1 = try await client.start(StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            database: database,
            workflowID: workflowID,
            kind: .design
        ))
        let session2 = try await client.start(StartRequest(
            prompt: "world",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            database: database,
            workflowID: workflowID,
            kind: .design
        ))

        async let r1 = client.send(SendRequest(prompt: "a", session: session1, database: database))
        async let r2 = client.send(SendRequest(prompt: "b", session: session2, database: database))

        let (result1, result2) = try await (r1, r2)
        #expect(result1.id == session1.id)
        #expect(result2.id == session2.id)
    }

    // A failing Turn must release the Session lock so the next send isn't rejected as busy.
    @Test func failedSendReleasesLock() async throws {
        let echoFixture = try fixtureURL("echo-init.sh")
        let crashFixture = try fixtureURL("crash.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await client(echoFixture).start(StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            database: database,
            workflowID: workflowID,
            kind: .design
        ))

        // Both sends share one client (and so one busySessions).
        let crashClient = client(crashFixture)

        do {
            _ = try await crashClient.send(SendRequest(prompt: "first", session: session, database: database))
            Issue.record("Expected AgentError to be thrown by crash fixture")
        } catch is AgentError {
            // expected — harnessFailed from crash.sh
        }

        // The second send must not throw .sessionBusy, proving the lock was released.
        do {
            _ = try await crashClient.send(SendRequest(prompt: "second", session: session, database: database))
        } catch let err as AgentError {
            if case .sessionBusy = err {
                Issue.record("Session lock was not released after failed send: \(err)")
            }
        }
    }
}
