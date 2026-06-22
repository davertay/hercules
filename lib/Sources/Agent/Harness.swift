import Foundation
import Store

public enum Harness {
    public enum Operation: Sendable {
        case start
        case resume
    }

    public static func renderArgs(
        binary: URL,
        operation: Operation,
        worktree: URL,
        mode: AgentMode,
        inputs: InputBundle?,
        skillFiles: [URL] = [],
        addDirs: [URL] = [],
        mcpServers: [MCPServer] = [],
        sessionDataDirectory: URL? = nil,
        extraArguments: [ExtraArgument] = [],
        sessionId: Session.ID
    ) throws -> [String] {
        var args: [String] = [
            "--print",
            "--output-format", "stream-json",
            // Realtime input keeps stdin open so we can interrupt mid-Turn on a question (see `SubProcess`).
            "--input-format", "stream-json",
            "--permission-mode", "bypassPermissions",
            "--setting-sources", "user,project,local",
            "--verbose",
            "--include-partial-messages",
        ]

        switch operation {
        case .start:
            args += ["--session-id", sessionId.rawValue.uuidString]
        case .resume:
            args += ["--resume", sessionId.rawValue.uuidString]
        }

        if mode == .readOnly {
            // MCP tools are allowed too: they write to the database, not the worktree, so the
            // read-only guarantee holds. Deriving from the descriptors keeps configured-and-allowed in step.
            var allowed = ["Read", "Grep", "Glob", "WebFetch", "WebSearch"]
            allowed += mcpServers.flatMap(\.qualifiedToolNames)
            args += ["--allowedTools"] + allowed
        }

        if !mcpServers.isEmpty {
            guard let sessionDataDirectory else {
                throw AgentError.mcpConfigDirectoryMissing
            }
            try FileManager.default.createDirectory(at: sessionDataDirectory, withIntermediateDirectories: true)
            let configURL = sessionDataDirectory.appendingPathComponent("mcp-config.json")
            try mcpConfigJSON(servers: mcpServers).write(to: configURL)
            args += ["--mcp-config", configURL.path]
        }

        if let inputs {
            args += ["--add-dir", inputs.root.path]
        }

        for dir in addDirs {
            args += ["--add-dir", dir.path]
        }

        for file in skillFiles {
            args += ["--append-system-prompt-file", file.path]
        }

        // The user's configured extras render last, after every Hercules-generated argument, so they
        // can override or extend whatever we produce.
        for argument in extraArguments {
            let flag = argument.flag.trimmingCharacters(in: .whitespacesAndNewlines)
            if flag.isEmpty { continue }
            if let value = argument.value, !value.isEmpty {
                args += [flag, value]
            } else {
                args.append(flag)
            }
        }

        return args
    }

    /// The `{"mcpServers": {...}}` payload, separated from the file write so it's testable. Keys sorted
    /// for deterministic output.
    static func mcpConfigJSON(servers: [MCPServer]) throws -> Data {
        var entries: [String: Any] = [:]
        for server in servers {
            entries[server.name] = [
                "command": server.command,
                "args": server.args,
                "env": server.env,
            ]
        }
        let root: [String: Any] = ["mcpServers": entries]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func renderPrompt(prompt: String, inputs: InputBundle?) -> String {
        guard let inputs, !inputs.relativePaths.isEmpty else {
            return prompt
        }
        let footer = inputs.relativePaths.map { "- \($0)" }.joined(separator: "\n")
        return "\(prompt)\n\nFiles available (read with your file-read tool):\n\(footer)"
    }
}
