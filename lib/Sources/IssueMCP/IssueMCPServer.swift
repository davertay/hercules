import Foundation
import MCP
import SQLiteData
import Store

// The stdio MCP server serving the `create_issue` write tool (ADR 0006): the app binary re-executed
// with `--mcp-issue-server --db <workflow.sqlite> --workflow-id <uuid>`. The DB path and workflow id
// are launch arguments fixed by the app and invisible to the model, so a call can't write to another
// Workflow.

/// The Harness allowlist entry is the qualified `mcp__hercules__create_issue`.
public let createIssueToolName = "create_issue"

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

/// A malformed call returns a tool error rather than tearing down the connection.
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

/// The `@main` re-exec branch, kept off the GUI path so the CLI invocation never initialises AppKit.
public enum IssueMCPLaunch {
    public static let subcommand = "--mcp-issue-server"

    public struct Configuration: Equatable, Sendable {
        /// Path to the Workflow's `workflow.sqlite` file.
        public var databasePath: String
        public var workflowID: UUID

        public init(databasePath: String, workflowID: UUID) {
            self.databasePath = databasePath
            self.workflowID = workflowID
        }
    }

    /// Returns `nil` when the subcommand is absent (the GUI path) or its operands are missing/invalid.
    public static func parse(_ arguments: [String]) -> Configuration? {
        guard arguments.contains(subcommand) else { return nil }
        guard
            let databasePath = value(of: "--db", in: arguments),
            let workflowIDString = value(of: "--workflow-id", in: arguments),
            let workflowID = UUID(uuidString: workflowIDString)
        else { return nil }
        return Configuration(databasePath: databasePath, workflowID: workflowID)
    }

    /// Runs the stdio server until the client closes the connection.
    public static func run(_ configuration: Configuration) async throws {
        let directory = URL(fileURLWithPath: configuration.databasePath).deletingLastPathComponent()
        let database = try openWorkflowDatabase(at: directory)
        let server = await makeIssueMCPServer(
            workflowID: configuration.workflowID, database: database
        )
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
