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

/// Validate's HITL proposal tool; allowlist entry `mcp__hercules__propose_issue`.
public let proposeIssueToolName = "propose_issue"

let proposeIssueTool = Tool(
    name: proposeIssueToolName,
    description: """
        Propose a fix as a HITL Issue in the current Workflow, for a human to approve before it runs. \
        Supply only the title and body — the Workflow, the Issue number, and its proposed status are \
        fixed by the host.
        """,
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "title": .object([
                "type": .string("string"),
                "description": .string("A short title for the proposed fix."),
            ]),
            "body": .object([
                "type": .string("string"),
                "description": .string("The bulk one-shot spec for the fix."),
            ]),
        ]),
        "required": .array([.string("title"), .string("body")]),
    ])
)

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

/// Serves one tool, selected by `propose`: Allocate's `create_issue` (model-numbered, `new`) or Validate's
/// `propose_issue` (host-numbered, `proposed`). A malformed call returns a tool error rather than tearing
/// down the connection.
public func makeIssueMCPServer(
    workflowID: UUID,
    database: any DatabaseWriter,
    propose: Bool = false
) async -> Server {
    let server = Server(
        name: "hercules",
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    let tool = propose ? proposeIssueTool : createIssueTool

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [tool])
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == tool.name else {
            return CallTool.Result(
                content: [.text(text: "Unknown tool \(params.name).", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        do {
            let row: IssueRow
            if propose {
                row = try proposeIssue(
                    ProposeIssueArguments(mcpArguments: params.arguments),
                    workflowID: workflowID, into: database
                )
                return CallTool.Result(
                    content: [.text(text: "Proposed Issue #\(row.number).", annotations: nil, _meta: nil)]
                )
            } else {
                row = try createIssue(
                    CreateIssueArguments(mcpArguments: params.arguments),
                    workflowID: workflowID, into: database
                )
                return CallTool.Result(
                    content: [.text(text: "Created Issue #\(row.number).", annotations: nil, _meta: nil)]
                )
            }
        } catch {
            return CallTool.Result(
                content: [.text(text: "\(tool.name) failed: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
}

/// The `@main` re-exec branch, kept off the GUI path so the CLI invocation never initialises AppKit.
public enum IssueMCPLaunch {
    public static let subcommand = "--mcp-issue-server"
    /// Selects the `propose_issue` tool (host-numbered, `proposed`) over `create_issue`.
    public static let proposeFlag = "--propose"

    public struct Configuration: Equatable, Sendable {
        /// Path to the Workflow's `workflow.sqlite` file.
        public var databasePath: String
        public var workflowID: UUID
        /// When `true`, serve `propose_issue` instead of `create_issue`.
        public var propose: Bool

        public init(databasePath: String, workflowID: UUID, propose: Bool = false) {
            self.databasePath = databasePath
            self.workflowID = workflowID
            self.propose = propose
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
        return Configuration(
            databasePath: databasePath,
            workflowID: workflowID,
            propose: arguments.contains(proposeFlag)
        )
    }

    /// Runs the stdio server until the client closes the connection.
    public static func run(_ configuration: Configuration) async throws {
        let directory = URL(fileURLWithPath: configuration.databasePath).deletingLastPathComponent()
        let database = try openWorkflowDatabase(at: directory)
        let server = await makeIssueMCPServer(
            workflowID: configuration.workflowID, database: database, propose: configuration.propose
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
