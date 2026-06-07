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

    // Two simultaneous sends on the same Session: the second throws .sessionBusy,
    // the first completes normally.
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
            workflowID: workflowID
        ))

        let slowClient = client(slowFixture)

        // First send: acquires lock and runs slow.sh (sleeps 30s).
        let firstTask = Task {
            try await slowClient.send(SendRequest(prompt: "first", session: session, database: database))
        }

        // Give slow.sh time to start and acquire the lock before the second send.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Second send on the same session must throw .sessionBusy immediately.
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

        // Cancel the slow first task to keep the test fast.
        firstTask.cancel()
        _ = try? await firstTask.value
    }

    // Two simultaneous sends on different Sessions: both proceed in parallel
    // without either throwing .sessionBusy.
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
            workflowID: workflowID
        ))
        let session2 = try await client.start(StartRequest(
            prompt: "world",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            database: database,
            workflowID: workflowID
        ))

        async let r1 = client.send(SendRequest(prompt: "a", session: session1, database: database))
        async let r2 = client.send(SendRequest(prompt: "b", session: session2, database: database))

        let (result1, result2) = try await (r1, r2)
        #expect(result1.id == session1.id)
        #expect(result2.id == session2.id)
    }

    // After a failing Turn the Session ID is removed from busySessions, so the
    // next send on the same client does not throw .sessionBusy.
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
            workflowID: workflowID
        ))

        // Use the crash client for both sends so they share the same busySessions.
        let crashClient = client(crashFixture)

        do {
            _ = try await crashClient.send(SendRequest(prompt: "first", session: session, database: database))
            Issue.record("Expected AgentError to be thrown by crash fixture")
        } catch is AgentError {
            // expected — harnessFailed from crash.sh
        }

        // Second send on the same client: must NOT throw .sessionBusy.
        // It will fail with .harnessFailed (crash.sh again), but that proves the
        // lock was correctly released by the defer in the first send.
        do {
            _ = try await crashClient.send(SendRequest(prompt: "second", session: session, database: database))
        } catch let err as AgentError {
            if case .sessionBusy = err {
                Issue.record("Session lock was not released after failed send: \(err)")
            }
            // .harnessFailed is expected; anything other than .sessionBusy is fine
        }
    }
}
