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

    // MARK: - Attended Turns

    /// The arguments the fixture was launched with, read back out of the worktree it wrote them into.
    private func launchedArguments(worktree: URL) throws -> [String] {
        try String(contentsOf: worktree.appendingPathComponent("harness-args.txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The appended system prompt the fixture was launched with, read back out of the worktree it copied
    /// it into: the file the argument names is Turn scratch, gone by the time the Turn returns.
    private func launchedSystemPrompt(worktree: URL) throws -> String {
        try String(contentsOf: worktree.appendingPathComponent("harness-system-prompt.md"), encoding: .utf8)
    }

    /// The appended system prompt a Turn carrying `files` is launched with: those documents, in that
    /// order, as the one file the Harness honours (ADR 0004).
    private static func composedPrompt(_ files: [URL]) throws -> String {
        String(decoding: try Harness.appendedSystemPrompt(composing: files), as: UTF8.self)
    }

    /// Offering to answer is the whole of what a caller does, and the Turn it gets is one that can ask:
    /// the `ask_user` server configured and allowlisted, pointed at a channel this Turn opened. The
    /// caller supplied no server and no directory — those are the Agent's, which is what leaves them
    /// free to change.
    @Test func aCallerWhoOffersToAnswerGetsATurnThatCanAsk() async throws {
        let fixture = try fixtureURL("dump-args.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let session = try await client(fixture).start(
            StartRequest(
                prompt: "hello",
                worktree: worktree,
                mode: .readOnly,
                database: database,
                workflowID: workflowID,
                kind: .design,
                onQuestion: { _ in .cancelled }
            )
        )
        defer {
            try? FileManager.default.removeItem(
                at: FileManager.default.temporaryDirectory
                    .appendingPathComponent("hercules-sessions", isDirectory: true)
                    .appendingPathComponent(session.id.rawValue.uuidString, isDirectory: true)
            )
        }

        let args = try launchedArguments(worktree: worktree)
        let allowed = try #require(args.firstIndex(of: "--allowedTools"))
        #expect(args[allowed...].contains("mcp__hercules_ask__ask_user"))

        // The tool and the rules for using it arrive together: a tool nobody told the model about is one
        // it never calls, and this caller pinned no Skill of its own, so the rules are the whole of the
        // appended prompt.
        #expect(args.filter { $0 == "--append-system-prompt-file" }.count == 1)
        #expect(try launchedSystemPrompt(worktree: worktree) == Self.composedPrompt([AttendedTurn.houseRules]))

        let configPath = args[try #require(args.firstIndex(of: "--mcp-config")) + 1]
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configPath)))
        let entry = ((config as! [String: Any])["mcpServers"] as! [String: Any])["hercules_ask"] as! [String: Any]
        let entryArgs = entry["args"] as! [String]
        #expect(entryArgs.first == "--mcp-ask-server")
        // The address is the Turn's own, under the Session's scratch — not anything the caller named.
        #expect(entryArgs.last?.hasSuffix(".questions") == true)
        #expect(entryArgs.last?.contains(session.id.rawValue.uuidString) == true)
    }

    /// And a caller that offers nothing gets exactly the invocation it got before any of this existed:
    /// no server, no tool, nothing to block on. This is what keeps an unattended Execute or Validate run
    /// unable to wedge itself on a question nobody is there to answer.
    @Test func aCallerWhoOffersNothingGetsTheInvocationItGotBefore() async throws {
        let fixture = try fixtureURL("dump-args.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        _ = try await client(fixture).start(
            StartRequest(
                prompt: "hello",
                worktree: worktree,
                mode: .readOnly,
                database: database,
                workflowID: workflowID,
                kind: .execute
            )
        )

        let args = try launchedArguments(worktree: worktree)
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains { $0.contains("ask_user") })
        // Neither half, not just the tool: an instruction to call a tool that isn't configured is an
        // instruction to call nothing, and an Execute agent that wants to ask is one that is stuck — it
        // has to fail where the run loop can see it rather than wait.
        #expect(!args.contains("--append-system-prompt-file"))
    }

    /// The Turn a Design summary or an Allocate commit runs as. Its writer rides a per-Turn override,
    /// which *replaces* the Session's pinned servers rather than merging into them — so the attended
    /// bundle is added to whatever that resolved to, and the Turn ends up carrying the writer, the
    /// question tool and the house rules at once. A last "did I capture this right?" question still has
    /// somewhere to go.
    @Test func aFinalizationTurnCarriesTheWriterTheQuestionToolAndTheHouseRules() async throws {
        let fixture = try fixtureURL("dump-args.sh")
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        // A real file: the Harness is handed the Skill's text composed with the house rules, not its path.
        let skill = root.appendingPathComponent("SKILL.md")
        try "# grill-me\n\nInterview the user.\n".write(to: skill, atomically: true, encoding: .utf8)

        let client = client(fixture)
        let session = try await client.start(
            StartRequest(
                prompt: "grill me",
                worktree: worktree,
                mode: .readOnly,
                database: database,
                workflowID: workflowID,
                kind: .design,
                skillFiles: [skill],
                onQuestion: { _ in .cancelled }
            )
        )
        defer {
            try? FileManager.default.removeItem(
                at: FileManager.default.temporaryDirectory
                    .appendingPathComponent("hercules-sessions", isDirectory: true)
                    .appendingPathComponent(session.id.rawValue.uuidString, isDirectory: true)
            )
        }
        _ = try await client.send(
            SendRequest(
                prompt: "write the summary",
                session: session,
                database: database,
                mcpServers: [
                    .artifactWriter(
                        command: "/path/to/Hercules",
                        artifactURL: root.appendingPathComponent("phases/design/summary.md")
                    )
                ],
                onQuestion: { _ in .cancelled }
            )
        )

        let args = try launchedArguments(worktree: worktree)
        let allowed = try #require(args.firstIndex(of: "--allowedTools"))
        #expect(args[allowed...].contains("mcp__hercules__write_artifact"))
        #expect(args[allowed...].contains("mcp__hercules_ask__ask_user"))

        let configPath = args[try #require(args.firstIndex(of: "--mcp-config")) + 1]
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configPath)))
        let entries = (config as! [String: Any])["mcpServers"] as! [String: Any]
        #expect(entries.keys.sorted() == ["hercules", "hercules_ask"])

        // The Phase's Skill and the house rules, in that order, in the one appended prompt the Harness
        // honours — as a second flag the rules silently displaced the Skill. The rules attach per Session
        // rather than per Skill, so an attended Turn reads the same ones whichever Skill is driving the Phase.
        #expect(args.filter { $0 == "--append-system-prompt-file" }.count == 1)
        #expect(
            try launchedSystemPrompt(worktree: worktree) == Self.composedPrompt([skill, AttendedTurn.houseRules])
        )
    }
}
