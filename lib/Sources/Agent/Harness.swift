import Foundation
import Store

public enum Harness {
    public enum Operation: Sendable {
        case start
        case resume
    }

    /// The settings a Session pins at start and re-passes on every resume Turn. It is an unbundled
    /// `Session` — on resume it is built from the real one, on start from the `StartRequest` that is
    /// about to become one — so the two runner paths spell it once each instead of field by field.
    public struct SessionConfiguration: Sendable {
        /// The Harness's cwd. Not rendered as an argument; passed to the subprocess directly.
        public var worktree: URL
        public var mode: AgentMode
        /// Rendered as one `--append-system-prompt-file` each (ADR 0004).
        public var skillFiles: [URL]
        /// Exposed via `--add-dir`, alongside any `InputBundle`.
        public var addDirs: [URL]
        public var mcpServers: [MCPServer]

        public init(
            worktree: URL,
            mode: AgentMode,
            skillFiles: [URL] = [],
            addDirs: [URL] = [],
            mcpServers: [MCPServer] = []
        ) {
            self.worktree = worktree
            self.mode = mode
            self.skillFiles = skillFiles
            self.addDirs = addDirs
            self.mcpServers = mcpServers
        }

        /// A resume Turn's configuration: the Session's own pins, except that a non-`nil` `mcpServers`
        /// overrides the pinned set for this Turn only, without mutating the Session (ADR 0001).
        public init(session: Session, mcpServers: [MCPServer]? = nil) {
            self.init(
                worktree: session.worktree,
                mode: session.mode,
                skillFiles: session.skillFiles,
                addDirs: session.addDirs,
                mcpServers: mcpServers ?? session.mcpServers
            )
        }

        /// A start Turn's configuration: what the request asks to pin, before the Session exists.
        public init(request: StartRequest) {
            self.init(
                worktree: request.worktree,
                mode: request.mode,
                skillFiles: request.skillFiles,
                addDirs: request.addDirs,
                mcpServers: request.mcpServers
            )
        }
    }

    /// The files a Turn generates for its Harness to read — the `--mcp-config` servers and the
    /// `--settings` hook registration — in the Session's data directory.
    ///
    /// The turn id keys whichever of them a Turn must not share with another. That is the
    /// ``StopFailureHook`` drop-file above all: one read as a later Turn's would misreport why that
    /// Turn ended. ``removeTurnFiles()`` clears them once the Turn is over, but that is best effort —
    /// the keying, not the removal, is what makes a stale read impossible.
    public struct TurnScratch: Sendable {
        public var directory: URL
        public var turnID: UUID

        public init(directory: URL, turnID: UUID) {
            self.directory = directory
            self.turnID = turnID
        }

        /// Rewritten every Turn, so a resume re-passes the pinned servers (ADR 0001).
        var mcpConfigFile: URL {
            directory.appendingPathComponent("mcp-config.json")
        }

        var hookSettingsFile: URL {
            directory.appendingPathComponent("\(turnID.uuidString).settings.json")
        }

        /// Where this Turn's `StopFailure` hook drops its payload; read back once the Harness exits.
        var stopFailureDropFile: URL {
            directory.appendingPathComponent("\(turnID.uuidString).stop-failure.json")
        }

        /// Removes the files keyed by this turn id, once the Turn has read everything it needs from
        /// them. Without this the Session's directory accumulates two files per Turn for the life of
        /// the temp directory. `mcp-config.json` and the directory itself stay: they are the Session's,
        /// not the Turn's.
        ///
        /// Best effort by construction — a temp file that won't delete is not a reason to change what a
        /// Turn reports.
        func removeTurnFiles() {
            for file in [hookSettingsFile, stopFailureDropFile] {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// `trustsRepositorySettings` is *not* part of ``SessionConfiguration``: it is resolved per Turn from
    /// the Workflow's current setting, not pinned when the Session starts.
    public static func renderArgs(
        binary: URL,
        operation: Operation,
        configuration: SessionConfiguration,
        trustsRepositorySettings: Bool = false,
        inputs: InputBundle?,
        scratch: TurnScratch? = nil,
        extraArguments: [ExtraArgument] = [],
        sessionId: Session.ID
    ) throws -> [String] {
        // We deliberately avoid `bypassPermissions`: enterprise-managed policy can forbid it
        let permissionMode = configuration.mode == .readOnly ? "default" : "acceptEdits"
        // `user` is settings the user deliberately authored for themselves (MCP servers, model
        // preference), so it always loads. `project`/`local` are settings that arrived with whatever
        // repository the Workflow was pointed at, and their hooks run shell commands inside a
        // semi-autonomous run with nobody watching each one fire — so they load only on the Workflow's
        // explicit opt-in.
        let settingSources = trustsRepositorySettings ? "user,project,local" : "user"
        var args: [String] = [
            "--print",
            "--output-format", "stream-json",
            // Realtime input keeps stdin open so we can interrupt mid-Turn on a question (see `SubProcess`).
            "--input-format", "stream-json",
            "--permission-mode", permissionMode,
            "--setting-sources", settingSources,
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
        let mcpTools = configuration.mcpServers.flatMap(\.qualifiedToolNames)
        switch configuration.mode {
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

        if let scratch {
            try FileManager.default.createDirectory(at: scratch.directory, withIntermediateDirectories: true)

            // Every Turn registers the StopFailure hook, so the reason it stopped arrives as a value
            // rather than as prose to be scraped. The settings file is written rather than passed
            // inline: `--settings` takes either, and a JSON literal on the command line is quoting hell.
            try StopFailureHook.settingsJSON(dropFile: scratch.stopFailureDropFile)
                .write(to: scratch.hookSettingsFile)
            args += ["--settings", scratch.hookSettingsFile.path]

            if !configuration.mcpServers.isEmpty {
                try mcpConfigJSON(servers: configuration.mcpServers).write(to: scratch.mcpConfigFile)
                args += ["--mcp-config", scratch.mcpConfigFile.path]
            }
        } else if !configuration.mcpServers.isEmpty {
            throw AgentError.mcpConfigDirectoryMissing
        }

        if let inputs {
            args += ["--add-dir", inputs.root.path]
        }

        for dir in configuration.addDirs {
            args += ["--add-dir", dir.path]
        }

        for file in configuration.skillFiles {
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
        // List absolute paths: the agent's working directory is the worktree, but these Artifacts live
        // under the bundle root (the Workflow directory, granted via --add-dir), so a bare relative path
        // would be resolved against the wrong directory and miss. Absolute is unambiguous regardless of cwd.
        let footer = inputs.relativePaths
            .map { "- \(inputs.root.appending(path: $0).path)" }
            .joined(separator: "\n")
        return "\(prompt)\n\nFiles available (read with your file-read tool):\n\(footer)"
    }
}
