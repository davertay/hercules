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
        // We deliberately avoid `bypassPermissions`: enterprise-managed policy can forbid it
        let permissionMode = mode == .readOnly ? "default" : "acceptEdits"
        var args: [String] = [
            "--print",
            "--output-format", "stream-json",
            // Realtime input keeps stdin open so we can interrupt mid-Turn on a question (see `SubProcess`).
            "--input-format", "stream-json",
            "--permission-mode", permissionMode,
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

        // MCP tools are allowlisted in both modes: in readOnly they write only to the database (so the
        // read-only guarantee holds), and in write mode `acceptEdits` doesn't auto-approve them.
        // Deriving from the descriptors keeps configured-and-allowed in step.
        let mcpTools = mcpServers.flatMap(\.qualifiedToolNames)
        switch mode {
        case .readOnly:
            // `gh` is allowlisted so the agent can read GitHub issues/PRs without prompting. Note this
            // also exposes gh's write subcommands; the read-only guarantee covers the local filesystem
            // and DB, not remote GitHub state.
            args += ["--allowedTools"] + ["Read", "Grep", "Glob", "WebFetch", "WebSearch", "Bash(gh:*)"] + mcpTools
        case .write:
            // `acceptEdits` already covers Write/Edit; Bash (build/test/lint/git) is the one broad
            // capability execute needs that it won't auto-approve, so allowlist it explicitly.
            args += ["--allowedTools"] + ["Bash"] + mcpTools
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
