import Dispatch
import Foundation
import IssueMCP

/// The argument branch the thin `@main` calls before any AppKit/SwiftUI setup.
public enum HerculesEntryPoint {
    /// When launched as one of the re-exec MCP servers, runs that stdio server to completion and exits —
    /// before the GUI boots. Returns normally when no server subcommand is present.
    public static func runMCPServerIfRequested(arguments: [String] = CommandLine.arguments) {
        if let configuration = IssueMCPLaunch.parse(arguments) {
            runToCompletion(label: "mcp-issue-server") { try await IssueMCPLaunch.run(configuration) }
        } else if let configuration = ArtifactMCPLaunch.parse(arguments) {
            runToCompletion(label: "mcp-artifact-server") { try await ArtifactMCPLaunch.run(configuration) }
        }
    }

    /// Blocks the calling thread on an async stdio server loop (there is no run loop yet at process
    /// start), then exits so a re-exec'd server never falls through to the GUI. Writes the failure to
    /// stderr and exits non-zero on error.
    private static func runToCompletion(
        label: String, _ body: @escaping @Sendable () async throws -> Void
    ) {
        nonisolated(unsafe) var failure: (any Error)?
        let done = DispatchSemaphore(value: 0)
        Task {
            do { try await body() } catch { failure = error }
            done.signal()
        }
        done.wait()

        if let failure {
            FileHandle.standardError.write(Data("\(label): \(failure)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
