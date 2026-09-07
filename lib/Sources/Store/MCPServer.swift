import Foundation

/// A custom MCP server for a Session's Turns, pinned at start and re-passed on every resume Turn
/// (ADR 0001 / ADR 0004). The Harness derives `--allowedTools` from `tools`, so a tool can never be
/// allowed without being configured.
public struct MCPServer: Codable, Sendable, Hashable {
    public let name: String
    public let command: String
    public let args: [String]
    public let env: [String: String]
    /// Unqualified tool names (e.g. `create_issue`); the allowlist entries are `mcp__<name>__<tool>`.
    public let tools: [String]

    public init(
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        tools: [String] = []
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.tools = tools
    }

    public var qualifiedToolNames: [String] {
        tools.map { "mcp__\(name)__\($0)" }
    }
}

/// The re-exec wire contract for the app's stdio MCP servers (ADR 0006): the launch flags the app
/// binary is re-executed with, the server name, and the tool names. The one home shared by the render
/// side (the feature models' descriptors, via the factories below) and the parse side (`IssueMCP`'s
/// launch parsers), so renaming a flag can't drift the two apart.
public enum HerculesMCP {
    /// The MCP server name; the Harness allowlist entries are `mcp__hercules__<tool>`.
    public static let serverName = "hercules"

    /// The server name for the blocking `ask_user` tool, yielding `mcp__hercules_ask__ask_user`.
    ///
    /// Its own name rather than the writers': ``Harness.mcpConfigJSON`` keys entries by server name, and
    /// a per-Turn override *replaces* the pinned set rather than merging into it. Sharing one name would
    /// leave the Design summary's finalization Turn — which already carries the artifact writer as an
    /// override — either silently without the question tool or with two entries colliding on one key.
    /// Two names let that Turn carry both descriptors, which is what a last "did I capture this right?"
    /// question needs.
    public static let askServerName = "hercules_ask"

    /// The `@main` re-exec subcommand serving `create_issue`/`propose_issue`.
    public static let issueServerSubcommand = "--mcp-issue-server"
    /// The `@main` re-exec subcommand serving `write_artifact`.
    public static let artifactServerSubcommand = "--mcp-artifact-server"
    /// The `@main` re-exec subcommand serving `ask_user`.
    public static let askServerSubcommand = "--mcp-ask-server"
    /// Selects `propose_issue` (host-numbered, `proposed`) over `create_issue` on the issue server.
    public static let proposeFlag = "--propose"
    /// Operand flag: path to the Workflow's `workflow.sqlite`.
    public static let databaseFlag = "--db"
    /// Operand flag: the Workflow's id, so a call can't write to another Workflow.
    public static let workflowIDFlag = "--workflow-id"
    /// Operand flag: the absolute destination the artifact server writes.
    public static let artifactPathFlag = "--artifact-path"
    /// Operand flag: the absolute directory a blocking `ask_user` call announces itself in and its
    /// answer comes back through. The Turn's own, so an answer can't be read as another Turn's.
    public static let questionChannelFlag = "--question-channel"

    public static let createIssueToolName = "create_issue"
    public static let proposeIssueToolName = "propose_issue"
    public static let writeArtifactToolName = "write_artifact"
    public static let askUserToolName = "ask_user"
}

extension MCPServer {
    /// The `write_artifact` writer pointed at one Phase Artifact — attached per-Turn by the Design
    /// summary and PRD finalizations, never pinned, so only the finalization Turn can write.
    public static func artifactWriter(command: String, artifactURL: URL) -> MCPServer {
        MCPServer(
            name: HerculesMCP.serverName,
            command: command,
            args: [HerculesMCP.artifactServerSubcommand, HerculesMCP.artifactPathFlag, artifactURL.path],
            tools: [HerculesMCP.writeArtifactToolName]
        )
    }

    /// The blocking `ask_user` asker, pointed at one Turn's question channel. Carried by attended
    /// Turns — the ones a human is watching — since a call that blocks on an answer nobody is there to
    /// give would wedge the Turn until it is torn down.
    ///
    /// The channel directory rides the launch arguments like the writers' destinations do (ADR 0006), so
    /// a call can only reach the Turn that spawned the server.
    public static func questionAsker(command: String, channelDirectory: URL) -> MCPServer {
        MCPServer(
            name: HerculesMCP.askServerName,
            command: command,
            args: [
                HerculesMCP.askServerSubcommand,
                HerculesMCP.questionChannelFlag, channelDirectory.path,
            ],
            tools: [HerculesMCP.askUserToolName]
        )
    }

    /// Allocate's `create_issue` writer — carried only by the commit Turn — or, with `propose: true`,
    /// Validate's `propose_issue` HITL proposer. The Workflow's Store path and id ride the launch
    /// arguments, invisible to the model (ADR 0006).
    public static func issueWriter(
        command: String, workflowDirectory: URL, workflowID: UUID, propose: Bool = false
    ) -> MCPServer {
        var args = [HerculesMCP.issueServerSubcommand]
        if propose { args.append(HerculesMCP.proposeFlag) }
        args += [
            HerculesMCP.databaseFlag, workflowDatabaseURL(in: workflowDirectory).path,
            HerculesMCP.workflowIDFlag, workflowID.uuidString,
        ]
        return MCPServer(
            name: HerculesMCP.serverName,
            command: command,
            args: args,
            tools: [propose ? HerculesMCP.proposeIssueToolName : HerculesMCP.createIssueToolName]
        )
    }
}
