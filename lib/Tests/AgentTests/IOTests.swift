import Dependencies
import DependenciesTestSupport
import Foundation
import SQLiteData
import Store
import Testing

@testable import Agent

@Suite(
    "IO — substituted binary",
    .dependency(\.uuid, .incrementing),
    .dependency(\.date, .constant(Date(timeIntervalSinceReferenceDate: 1_234_567_890)))
)
struct IOTests {
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
            $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
        } operation: {
            LiveAgentClient(binaryURL: fixture)
        }
    }

    private func startRequest(prompt: String = "hello", database: any DatabaseWriter, workflowID: UUID) -> StartRequest {
        StartRequest(
            prompt: prompt,
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            database: database,
            workflowID: workflowID,
            kind: .design
        )
    }

    @Test func streamedTextIsProjectedIntoDatabase() async throws {
        let fixture = try fixtureURL("stream-text.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))

        let sessions = try await database.read { db in try SessionRow.fetchAll(db) }
        #expect(sessions.map(\.id) == [session.id.rawValue])

        let turns = try await database.read { db in try TurnRow.fetchAll(db) }
        let turn = try #require(turns.first)
        #expect(turns.count == 1)
        #expect(turn.sessionID == session.id.rawValue)
        #expect(turn.userPrompt == "hello")
        #expect(turn.finalAnswer == "Hello, world")
        #expect(turn.isError == false)
        #expect(turn.durationMs == 1234)
        #expect(turn.costUSD == 0.25)

        let blocks = try await database.read { db in try ContentBlockRow.fetchAll(db) }
        let block = try #require(blocks.first)
        #expect(blocks.count == 1)
        #expect(block.turnID == turn.id)
        #expect(block.kind == "text")
        #expect(block.text == "Hello, world")
    }

    @Test func askUserQuestionInterruptsTurnAndPausesCleanly() async throws {
        let fixture = try fixtureURL("ask-user-question.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        // The fixture drains its stdin to this file, so we can prove the harness wrote the interrupt.
        let capture = "/tmp/auq_stdin_capture.log"
        try? FileManager.default.removeItem(atPath: capture)

        _ = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))

        // The harness sent an interrupt control_request on stdin in response to the question.
        let written = (try? String(contentsOfFile: capture, encoding: .utf8)) ?? ""
        #expect(written.contains(#""subtype":"interrupt""#))

        // The interrupted result reads as an error, but pausing for a question is a clean stop.
        let turn = try #require(try await database.read { db in try TurnRow.fetchAll(db) }.first)
        #expect(turn.isError == false)

        // The question card is projected; the auto-error tool_result is suppressed.
        let blocks = try await database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.contains { $0.kind == "tool_use" && $0.toolName == "AskUserQuestion" })
        #expect(!blocks.contains { $0.kind == "tool_result" })
    }

    @Test func echoInitWritesSessionAndTurnRows() async throws {
        let fixture = try fixtureURL("echo-init.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))

        let sessions = try await database.read { db in try SessionRow.fetchAll(db) }
        let sessionRow = try #require(sessions.first)
        #expect(sessionRow.id == session.id.rawValue)
        #expect(sessionRow.mode == "write")

        let turns = try await database.read { db in try TurnRow.fetchAll(db) }
        let turn = try #require(turns.first)
        #expect(turn.userPrompt == "hello")
        // init-only stream emits no content blocks and no result event.
        #expect(turn.finalAnswer == nil)
        #expect(turn.isError == false)
        let blocks = try await database.read { db in try ContentBlockRow.fetchAll(db) }
        #expect(blocks.isEmpty)
    }

    @Test func malformedLineWithCleanExitSucceeds() async throws {
        let fixture = try fixtureURL("malformed.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        // A malformed line on a clean exit is ignored, not fatal.
        _ = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))

        let turns = try await database.read { db in try TurnRow.fetchAll(db) }
        let turn = try #require(turns.first)
        #expect(turn.isError == false)
    }

    @Test func malformedLineWithFailedExitThrowsMalformedStream() async throws {
        let fixture = try fixtureURL("malformed-fail.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))
            Issue.record("Expected AgentError.malformedStream to be thrown")
        } catch let err as AgentError {
            guard case .malformedStream(let line, _) = err else {
                Issue.record("Expected .malformedStream, got \(err)")
                return
            }
            #expect(line.contains("not valid json"))
        }

        let turns = try await database.read { db in try TurnRow.fetchAll(db) }
        #expect(turns.first?.isError == true)
    }

    @Test func largeStderrCarries64KBTailAndFlagsTurn() async throws {
        let fixture = try fixtureURL("large-stderr.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))
            Issue.record("Expected AgentError.harnessFailed to be thrown")
            return
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let stderrTail, _) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(exitCode == 1)
            #expect(stderrTail.count == 65536)
            #expect(stderrTail.allSatisfy { $0 == "Y" })
        }

        let turns = try await database.read { db in try TurnRow.fetchAll(db) }
        #expect(turns.first?.isError == true)
    }

    @Test func inputUnreadableThrownBeforeAnyRow() async throws {
        let fixture = try fixtureURL("echo-init.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = InputBundle(root: missingDir, relativePaths: ["file.txt"])

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            inputs: bundle,
            database: database,
            workflowID: workflowID,
            kind: .design
        )

        do {
            _ = try await client(fixture).start(request)
            Issue.record("Expected AgentError.inputUnreadable to be thrown")
        } catch let err as AgentError {
            guard case .inputUnreadable(let url, _) = err else {
                Issue.record("Expected .inputUnreadable, got \(err)")
                return
            }
            #expect(url == missingDir)
            let sessions = try await database.read { db in try SessionRow.fetchAll(db) }
            #expect(sessions.isEmpty)
        }
    }

    @Test func startThenSendWritesTwoTurns() async throws {
        let fixture = try fixtureURL("echo-init.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = client(fixture)
        let session = try await client.start(startRequest(database: database, workflowID: workflowID))
        let resumed = try await client.send(SendRequest(prompt: "follow up", session: session, database: database))
        #expect(resumed.id == session.id)

        let sessions = try await database.read { db in try SessionRow.fetchAll(db) }
        #expect(sessions.count == 1)
        let turns = try await database.read { db in try TurnRow.fetchAll(db) }
        #expect(turns.count == 2)
        #expect(Set(turns.map(\.userPrompt)) == ["hello", "follow up"])
        #expect(turns.allSatisfy { $0.sessionID == session.id.rawValue })
    }

    @Test func failingSendLeavesSessionReusable() async throws {
        let initFixture = try fixtureURL("echo-init.sh")
        let crashFixture = try fixtureURL("crash.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await client(initFixture).start(startRequest(database: database, workflowID: workflowID))

        do {
            _ = try await client(crashFixture).send(SendRequest(prompt: "crash me", session: session, database: database))
            Issue.record("Expected AgentError to be thrown")
        } catch is AgentError {
            // expected
        }

        // The session remains usable for a subsequent Turn.
        _ = try await client(initFixture).send(SendRequest(prompt: "retry", session: session, database: database))

        let turns = try await database.read { db in try TurnRow.fetchAll(db) }
        #expect(turns.count == 3)
    }

    @Test func sessionNotFoundThrowsSessionNotFound() async throws {
        let initFixture = try fixtureURL("echo-init.sh")
        let notFoundFixture = try fixtureURL("session-not-found.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await client(initFixture).start(startRequest(database: database, workflowID: workflowID))

        do {
            _ = try await client(notFoundFixture).send(SendRequest(prompt: "follow up", session: session, database: database))
            Issue.record("Expected AgentError.sessionNotFound to be thrown")
        } catch let err as AgentError {
            guard case .sessionNotFound(let id) = err else {
                Issue.record("Expected .sessionNotFound, got \(err)")
                return
            }
            #expect(id == session.id)
        }
    }

    @Test func unrunnableBinaryThrowsHarnessNotFound() async throws {
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        // A resolved-but-unrunnable path (e.g. a misconfigured agentExecutablePath) surfaces at run time.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        do {
            _ = try await client(missing).start(startRequest(database: database, workflowID: workflowID))
            Issue.record("Expected AgentError.harnessNotFound to be thrown")
        } catch let err as AgentError {
            guard case .harnessNotFound(let triedPath) = err else {
                Issue.record("Expected .harnessNotFound, got \(err)")
                return
            }
            #expect(triedPath == missing)
        }
    }

    @Test func crashThrowsHarnessFailed() async throws {
        let fixture = try fixtureURL("crash.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))
            Issue.record("Expected AgentError.harnessFailed to be thrown")
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let stderrTail, _) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(exitCode == 1)
            #expect(stderrTail.contains("harness failed"))
        }
    }

    // MARK: - StopFailure hook

    /// The consumption path end to end: the fixture runs the hook command out of the `--settings` file
    /// we generated — a fake harness can't fire a real hook — and the reason it drops reaches the
    /// failure the Turn throws, alongside the Harness's own wording.
    @Test func stopFailureDropFileCarriesTheReasonIntoTheFailure() async throws {
        let fixture = try fixtureURL("stop-failure.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))
            Issue.record("Expected AgentError.harnessFailed to be thrown")
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let stderrTail, let reason) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(exitCode == 1)
            #expect(reason == "rate_limit")
            #expect(stderrTail.contains("session limit"))
            #expect(err.localizedDescription.contains("(rate_limit)"))
        }

        let turns = try await database.read { db in try TurnRow.fetchAll(db) }
        #expect(turns.first?.isError == true)
    }

    /// The property the whole hook design rests on: with no drop-file — no hook fired, a Harness that
    /// doesn't have the event, a failure it doesn't cover — the Turn fails exactly as it did before the
    /// hook existed, down to the wording of the error.
    @Test func absentDropFileFailsExactlyAsBefore() async throws {
        let fixture = try fixtureURL("crash.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))
            Issue.record("Expected AgentError.harnessFailed to be thrown")
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let stderrTail, let reason) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(reason == nil)
            #expect(exitCode == 1)
            #expect(stderrTail.contains("harness failed"))
            // No reason, no clause: the message is the one this failure has always produced.
            #expect(err.localizedDescription == "Harness failed code=1: \(stderrTail)")
        }

        let turns = try await database.read { db in try TurnRow.fetchAll(db) }
        #expect(turns.first?.isError == true)
    }

    /// The Turn's own files don't outlive it. `stop-failure.sh` drops a payload the way the hook does,
    /// and the reason still reaches the thrown failure — so the removal ran after the read, not
    /// instead of it. What's left in the Session's directory is the Session's: `mcp-config.json`, and
    /// the directory itself.
    @Test func turnFilesAreRemovedOnceTheTurnHasReadThem() async throws {
        let fixture = try fixtureURL("stop-failure.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        // Pinned so the test knows which Session directory to inspect once the Turn has thrown.
        let sessionID = UUID()
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hercules-sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            database: database,
            workflowID: workflowID,
            kind: .design,
            sessionID: sessionID,
            mcpServers: [MCPServer(name: "hercules", command: "/bin/true", tools: ["create_issue"])]
        )

        do {
            _ = try await client(fixture).start(request)
            Issue.record("Expected AgentError.harnessFailed to be thrown")
        } catch let err as AgentError {
            guard case .harnessFailed(_, _, let reason) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(reason == "rate_limit")
        }

        // Throws if the directory went with them.
        let left = try FileManager.default.contentsOfDirectory(atPath: scratchDirectory.path)
        #expect(!left.contains { $0.hasSuffix(".stop-failure.json") || $0.hasSuffix(".settings.json") })
        #expect(left.contains("mcp-config.json"))
    }

    /// A drop-file that isn't a payload we can read is the absent one: the Turn fails on its own
    /// evidence rather than on a half-written file.
    @Test func malformedDropFileIsTreatedAsAbsent() async throws {
        let fixture = try fixtureURL("stop-failure-malformed.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await client(fixture).start(startRequest(database: database, workflowID: workflowID))
            Issue.record("Expected AgentError.harnessFailed to be thrown")
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let stderrTail, let reason) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(reason == nil)
            #expect(exitCode == 1)
            #expect(err.localizedDescription == "Harness failed code=1: \(stderrTail)")
        }
    }
}
