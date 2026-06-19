import Foundation

/// A custom MCP server made available to a Session's Turns. Threaded the same way `skillFiles` and
/// `addDirs` are: pinned on the `Session` at start and re-passed on every resume Turn (ADR 0001 /
/// ADR 0004).
///
/// `name`, `command`, `args`, and `env` describe the `--mcp-config` entry the Harness writes; `tools`
/// lists the unqualified tool names the server exposes so the Harness can *derive* the
/// `--allowedTools` additions from one source of truth — a tool can never be allowed without being
/// configured.
public struct MCPServer: Codable, Sendable, Hashable {
    public let name: String
    public let command: String
    public let args: [String]
    public let env: [String: String]
    /// The unqualified tool names the server exposes (e.g. `create_issue`). The Harness allowlist
    /// additions are derived from these as `mcp__<name>__<tool>`.
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

    /// Fully-qualified tool names for the Harness `--allowedTools` flag, in `mcp__<name>__<tool>` form.
    public var qualifiedToolNames: [String] {
        tools.map { "mcp__\(name)__\($0)" }
    }
}
