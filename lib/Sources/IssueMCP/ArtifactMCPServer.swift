import Foundation
import MCP

// The stdio MCP server serving the `write_artifact` writer tool (ADR 0006): the app binary re-executed
// with `--mcp-artifact-server --artifact-path <abs path>`. The destination path is a launch argument
// fixed by the app and invisible to the model, so a call can only write the Phase's own Artifact. Unlike
// the issue server, this writer needs no `--db`/`--workflow-id`: it writes a file, not Store rows.

let writeArtifactTool = Tool(
    name: writeArtifactToolName,
    description: """
        Save the current Phase's document. Call once with the complete markdown; the destination file is \
        fixed by the host, so you supply only the content.
        """,
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "markdown": .object([
                "type": .string("string"),
                "description": .string("The complete markdown document to save."),
            ]),
        ]),
        "required": .array([.string("markdown")]),
    ])
)

/// Serves the single `write_artifact` tool, writing to the host-fixed `artifactPath`. A malformed call
/// returns a tool error rather than tearing down the connection.
public func makeArtifactMCPServer(artifactPath: String) async -> Server {
    let server = Server(
        name: "hercules",
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [writeArtifactTool])
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == writeArtifactTool.name else {
            return CallTool.Result(
                content: [.text(text: "Unknown tool \(params.name).", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        do {
            try writeArtifact(WriteArtifactArguments(mcpArguments: params.arguments), to: artifactPath)
            return CallTool.Result(
                content: [.text(text: "Wrote artifact to \(artifactPath).", annotations: nil, _meta: nil)]
            )
        } catch {
            return CallTool.Result(
                content: [
                    .text(text: "\(writeArtifactTool.name) failed: \(error)", annotations: nil, _meta: nil)
                ],
                isError: true
            )
        }
    }

    return server
}

/// The `@main` re-exec branch, kept off the GUI path so the CLI invocation never initialises AppKit.
public enum ArtifactMCPLaunch {
    public static let subcommand = "--mcp-artifact-server"

    public struct Configuration: Equatable, Sendable {
        /// Absolute path the Phase's markdown Artifact is written to.
        public var artifactPath: String

        public init(artifactPath: String) {
            self.artifactPath = artifactPath
        }
    }

    /// Returns `nil` when the subcommand is absent (the GUI path) or its operand is missing.
    public static func parse(_ arguments: [String]) -> Configuration? {
        guard arguments.contains(subcommand) else { return nil }
        guard let artifactPath = value(of: "--artifact-path", in: arguments) else { return nil }
        return Configuration(artifactPath: artifactPath)
    }

    /// Runs the stdio server until the client closes the connection.
    public static func run(_ configuration: Configuration) async throws {
        let server = await makeArtifactMCPServer(artifactPath: configuration.artifactPath)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
