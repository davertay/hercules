import Dispatch
import Foundation
import IssueMCP

/// The argument branch the thin `@main` calls before any AppKit/SwiftUI setup. Kept in the library so
/// the entry point stays a one-liner and the branching logic is shared with `IssueMCP`.
public enum HerculesEntryPoint {
    /// When launched as the create-issue MCP server (`--mcp-issue-server --db … --workflow-id …`),
    /// runs that stdio server to completion and terminates the process — **before** the GUI boots.
    /// Returns normally (so the caller boots the GUI unchanged) when the subcommand is absent.
    public static func runMCPServerIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let configuration = IssueMCPLaunch.parse(arguments) else { return }

        // We are at process start with no run loop yet, so block the calling thread on the async
        // server loop. `run` returns when the client closes the stdio connection.
        nonisolated(unsafe) var failure: (any Error)?
        let done = DispatchSemaphore(value: 0)
        Task {
            do { try await IssueMCPLaunch.run(configuration) } catch { failure = error }
            done.signal()
        }
        done.wait()

        if let failure {
            FileHandle.standardError.write(Data("mcp-issue-server: \(failure)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
