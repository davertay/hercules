import Dispatch
import Foundation
import IssueMCP

/// The argument branch the thin `@main` calls before any AppKit/SwiftUI setup.
public enum HerculesEntryPoint {
    /// When launched as the create-issue MCP server, runs that stdio server to completion and exits —
    /// before the GUI boots. Returns normally when the subcommand is absent.
    public static func runMCPServerIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let configuration = IssueMCPLaunch.parse(arguments) else { return }

        // No run loop yet at process start, so block the calling thread on the async server loop.
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
