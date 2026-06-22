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
