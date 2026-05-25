#if os(macOS)
import Foundation
import Testing

@testable import Agent

@Suite("IO — substituted binary")
struct IOTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.bundleURL
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
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

        let impl = LiveAgentClient(binaryURL: fixture)
        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            storageRoot: storageRoot
        )

        let session = try await impl.start(request)

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

    @Test func crashThrowsHarnessFailed() async throws {
        let fixture = try fixtureURL("crash.sh")
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let impl = LiveAgentClient(binaryURL: fixture)
        let request = StartRequest(
            prompt: "hello",
            worktree: FileManager.default.temporaryDirectory,
            mode: .write,
            storageRoot: storageRoot
        )

        do {
            _ = try await impl.start(request)
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
#endif
