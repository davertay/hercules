import Dependencies
import Foundation
import Testing

@testable import Agent

@Suite("IO — substituted binary")
struct IOTests {
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

    @Test func echoInitSucceeds() async throws {
        let fixture = try fixtureURL("echo-init.sh")
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let client = withDependencies {
          $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
        } operation: {
            LiveAgentClient(binaryURL: fixture)
        }

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            storageRoot: storageRoot
        )

        let session = try await client.start(request)

        #expect(FileManager.default.fileExists(atPath: session.transcript.path))
        let lines = try String(contentsOf: session.transcript, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count >= 3)

        let firstLine = try #require(lines.first.map(String.init))
        let parsed = try parseTranscriptLine(firstLine.data(using: .utf8)!)
        if case .hercules(.sessionStarted) = parsed {} else {
            Issue.record("Expected hercules.session.started as first line, got: \(firstLine)")
        }

        let lastLine = String(lines.last!)
        let parsedLast = try parseTranscriptLine(lastLine.data(using: .utf8)!)
        if case .hercules(.turnEnded) = parsedLast {} else {
            Issue.record("Expected hercules.turn.ended as last line, got: \(lastLine)")
        }
    }

    @Test func largeStderrCarries64KBTail() async throws {
        let fixture = try fixtureURL("large-stderr.sh")
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let client = withDependencies {
            $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
        } operation: {
            LiveAgentClient(binaryURL: fixture)
        }

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            storageRoot: storageRoot
        )

        var tailFromError = ""
        do {
            _ = try await client.start(request)
            Issue.record("Expected AgentError.harnessFailed to be thrown")
            return
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let stderrTail) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(exitCode == 1)
            #expect(stderrTail.count == 65536)
            #expect(stderrTail.allSatisfy { $0 == "Y" })
            tailFromError = stderrTail
        }

        let sessionDirs = try FileManager.default.contentsOfDirectory(
            at: storageRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        let transcriptURL = try #require(sessionDirs.first).appendingPathComponent("transcript.jsonl")
        let lines = try String(contentsOf: transcriptURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)

        var turnFailed: HerculesEvent.TurnFailed?
        for line in lines {
            if case .hercules(.turnFailed(let tf)) = try parseTranscriptLine(Data(line.utf8)) {
                turnFailed = tf
            }
        }
        let tf = try #require(turnFailed)
        #expect(tf.errorKind == "harnessFailed")
        #expect(tf.errorMessage == tailFromError)
    }

    @Test func inputUnreadableThrownBeforeDataDir() async throws {
        let fixture = try fixtureURL("echo-init.sh")
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let client = withDependencies {
            $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
        } operation: {
            LiveAgentClient(binaryURL: fixture)
        }

        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = InputBundle(root: missingDir, relativePaths: ["file.txt"])

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            inputs: bundle,
            storageRoot: storageRoot
        )

        do {
            _ = try await client.start(request)
            Issue.record("Expected AgentError.inputUnreadable to be thrown")
        } catch let err as AgentError {
            guard case .inputUnreadable(let url, _) = err else {
                Issue.record("Expected .inputUnreadable, got \(err)")
                return
            }
            #expect(url == missingDir)
            let contents = try FileManager.default.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: nil)
            #expect(contents.isEmpty)
        }
    }

    @Test func startThenSendSucceeds() async throws {
        let fixture = try fixtureURL("echo-init.sh")
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let client = withDependencies {
            $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
        } operation: {
            LiveAgentClient(binaryURL: fixture)
        }

        let session = try await client.start(StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            storageRoot: storageRoot
        ))

        let resumed = try await client.send(SendRequest(prompt: "follow up", session: session))
        #expect(resumed.id == session.id)

        let lines = try String(contentsOf: session.transcript, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)

        var sessionStartedCount = 0
        var turnStartedCount = 0
        var turnEndedCount = 0
        for line in lines {
            let parsed = try parseTranscriptLine(line.data(using: .utf8)!)
            if case .hercules(let event) = parsed {
                switch event {
                case .sessionStarted: sessionStartedCount += 1
                case .turnStarted: turnStartedCount += 1
                case .turnEnded: turnEndedCount += 1
                case .turnFailed: break
                }
            }
        }
        #expect(sessionStartedCount == 1)
        #expect(turnStartedCount == 2)
        #expect(turnEndedCount == 2)
    }

    @Test func failingSendLeavesSessionReusable() async throws {
        let initFixture = try fixtureURL("echo-init.sh")
        let crashFixture = try fixtureURL("crash.sh")
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let initClient = withDependencies {
            $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
        } operation: {
            LiveAgentClient(binaryURL: initFixture)
        }

        let session = try await initClient.start(StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            storageRoot: storageRoot
        ))

        let transcriptBefore = try String(contentsOf: session.transcript, encoding: .utf8)

        let crashClient = withDependencies {
            $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
        } operation: {
            LiveAgentClient(binaryURL: crashFixture)
        }

        do {
            _ = try await crashClient.send(SendRequest(prompt: "crash me", session: session))
            Issue.record("Expected AgentError to be thrown")
        } catch is AgentError {
            // expected
        }

        let transcriptAfterFail = try String(contentsOf: session.transcript, encoding: .utf8)
        #expect(transcriptAfterFail.hasPrefix(transcriptBefore))

        _ = try await initClient.send(SendRequest(prompt: "retry", session: session))
    }

    @Test func crashThrowsHarnessFailed() async throws {
        let fixture = try fixtureURL("crash.sh")
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let client = withDependencies {
          $0.date.now = Date(timeIntervalSinceReferenceDate: 1234567890)
        } operation: {
            LiveAgentClient(binaryURL: fixture)
        }

        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            storageRoot: storageRoot
        )

        do {
            _ = try await client.start(request)
            Issue.record("Expected AgentError.harnessFailed to be thrown")
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let stderrTail) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(exitCode == 1)
            #expect(stderrTail.contains("harness failed"))
        }
    }
}
