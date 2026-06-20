import Foundation
import MCP
import SQLiteData
import Store

// The stdio MCP server that serves the `create_issue` write tool (ADR 0006). It is the Hercules app
// binary re-executed with `--mcp-issue-server --db <workflow.sqlite> --workflow-id <uuid>`; it opens
// that one Workflow database and inserts Issue rows there. The database path and workflow id are
// launch arguments fixed by the app and invisible to the model, so a tool call can never write to
// another Workflow.

/// The unqualified name of the create-issue tool. The Harness allowlist entry is the qualified
/// `mcp__hercules__create_issue` derived from the server name plus this.
public let createIssueToolName = "create_issue"

/// The `create_issue` tool descriptor returned by `tools/list`.
let createIssueTool = Tool(
    name: createIssueToolName,
    description: """
        Create one Allocate Issue in the current Workflow. Call once per Issue. The Issue's Workflow \
        is fixed by the host; you supply only the content.
        """,
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "number": .object([
                "type": .string("integer"),
                "description": .string("The per-Workflow 1…N number you assigned this Issue."),
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("A short title for the Issue."),
            ]),
            "body": .object([
                "type": .string("string"),
                "description": .string("The bulk one-shot spec for the Issue."),
            ]),
            "dependencies": .object([
                "type": .string("array"),
                "items": .object(["type": .string("integer")]),
                "description": .string("The numbers of the other Issues this one depends on."),
            ]),
        ]),
        "required": .array([.string("number"), .string("title"), .string("body")]),
    ])
)

/// Builds the MCP `Server` that serves `create_issue`, wiring `tools/list` and `tools/call` to insert
/// rows into `database` for `workflowID`. The handler decodes the model's arguments and, on a
/// malformed call, returns a tool error rather than tearing down the connection.
public func makeIssueMCPServer(
    workflowID: UUID,
    database: any DatabaseWriter
) async -> Server {
    let server = Server(
        name: "hercules",
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [createIssueTool])
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == createIssueToolName else {
            return CallTool.Result(
                content: [.text(text: "Unknown tool \(params.name).", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        do {
            let arguments = try CreateIssueArguments(mcpArguments: params.arguments)
            let row = try createIssue(arguments, workflowID: workflowID, into: database)
            return CallTool.Result(
                content: [.text(text: "Created Issue #\(row.number).", annotations: nil, _meta: nil)]
            )
        } catch {
            return CallTool.Result(
                content: [
                    .text(text: "create_issue failed: \(error)", annotations: nil, _meta: nil)
                ],
                isError: true
            )
        }
    }

    return server
}

/// The `@main` re-exec branch: parse the launch arguments, open the named Workflow database, and run
/// the stdio MCP server loop. Kept off the GUI path so the CLI invocation never initialises AppKit.
public enum IssueMCPLaunch {
    /// The subcommand flag that selects the create-issue MCP server instead of the GUI.
    public static let subcommand = "--mcp-issue-server"

    /// The launch context fixed by the app: which Workflow database to open and which Workflow the
    /// inserted Issues belong to.
    public struct Configuration: Equatable, Sendable {
        /// Path to the Workflow's `workflow.sqlite` file.
        public var databasePath: String
        public var workflowID: UUID

        public init(databasePath: String, workflowID: UUID) {
            self.databasePath = databasePath
            self.workflowID = workflowID
        }
    }

    /// Parses `--mcp-issue-server --db <path> --workflow-id <uuid>` out of `arguments`, returning
    /// `nil` when the subcommand is absent (the GUI path) or its operands are missing/invalid.
    public static func parse(_ arguments: [String]) -> Configuration? {
        guard arguments.contains(subcommand) else { return nil }
        guard
            let databasePath = value(of: "--db", in: arguments),
            let workflowIDString = value(of: "--workflow-id", in: arguments),
            let workflowID = UUID(uuidString: workflowIDString)
        else { return nil }
        return Configuration(databasePath: databasePath, workflowID: workflowID)
    }

    /// Opens the Workflow database named by `configuration` (migrations idempotent via
    /// `openWorkflowDatabase`) and runs the stdio server until the client closes the connection.
    public static func run(_ configuration: Configuration) async throws {
        let directory = URL(fileURLWithPath: configuration.databasePath).deletingLastPathComponent()
        let database = try openWorkflowDatabase(at: directory)
        let server = await makeIssueMCPServer(
            workflowID: configuration.workflowID, database: database
        )
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// The operand following `flag` in `arguments`, or `nil` when `flag` is absent or trailing.
    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
