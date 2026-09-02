import CustomDump
import Foundation
import SQLiteData
import SnapshotTesting
import SnapshotTestingCustomDump
import Testing
import Store

@testable import Agent

@Suite("Harness.renderArgs")
struct HarnessRenderArgsTests {
    let binary = URL(fileURLWithPath: "/usr/local/bin/claude")
    let worktree = URL(fileURLWithPath: "/tmp/wt")
    let inputsRoot = URL(fileURLWithPath: "/tmp/inputs")
    let sessionId = Session.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let turnID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    /// The session-pinned configuration under test, over the suite's fixed worktree.
    private func configuration(
        mode: AgentMode,
        skillFiles: [URL] = [],
        addDirs: [URL] = [],
        mcpServers: [MCPServer] = []
    ) -> Harness.SessionConfiguration {
        Harness.SessionConfiguration(
            worktree: worktree,
            mode: mode,
            skillFiles: skillFiles,
            addDirs: addDirs,
            mcpServers: mcpServers
        )
    }

    @Test func startWriteNoInputs() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--output-format"))
        let outputFormatIdx = args.firstIndex(of: "--output-format")!
        #expect(args[args.index(after: outputFormatIdx)] == "stream-json")

        #expect(args.contains("--session-id"))
        let sessionIdIdx = args.firstIndex(of: "--session-id")!
        #expect(args[args.index(after: sessionIdIdx)] == sessionId.rawValue.uuidString)

        #expect(!args.contains("--resume"))
        #expect(!args.contains("--mcp-config"))

        // Write mode runs under acceptEdits (never bypassPermissions, which managed policy can forbid)
        // and allowlists Bash so build/test/git run unattended; Write/Edit are covered by the mode.
        let permIdx = args.firstIndex(of: "--permission-mode")!
        #expect(args[permIdx + 1] == "acceptEdits")
        let allowedIdx = args.firstIndex(of: "--allowedTools")!
        #expect(args[allowedIdx + 1] == "Bash")
    }

    @Test func startWriteWithInputs() throws {
        let inputs = InputBundle(root: inputsRoot, relativePaths: ["a.txt", "b.md"])
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: inputs,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--add-dir"))
        let addDirIdx = args.firstIndex(of: "--add-dir")!
        #expect(args[args.index(after: addDirIdx)] == inputsRoot.path)
        #expect(!args.contains("--resume"))
    }

    @Test func resumeReadOnlyWithInputs() throws {
        let inputs = InputBundle(root: inputsRoot, relativePaths: ["c.swift"])
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            configuration: configuration(mode: .readOnly),
            inputs: inputs,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--resume"))
        #expect(!args.contains("--session-id"))
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("--add-dir"))
        let addDirIdx = args.firstIndex(of: "--add-dir")!
        #expect(args[args.index(after: addDirIdx)] == inputsRoot.path)
    }

    @Test func resumeWriteNoInputs() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            configuration: configuration(mode: .write),
            inputs: nil,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--resume"))
        let resumeIdx = args.firstIndex(of: "--resume")!
        #expect(args[args.index(after: resumeIdx)] == sessionId.rawValue.uuidString)
        #expect(!args.contains("--session-id"))

        let startArgs = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            sessionId: sessionId
        )
        #expect(!startArgs.contains("--resume"))
    }

    @Test func startReadOnlyNoInputs() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .readOnly),
            inputs: nil,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--allowedTools"))
        let allowedIdx = args.firstIndex(of: "--allowedTools")!
        #expect(args[allowedIdx + 1] == "Read")
        #expect(args[allowedIdx + 2] == "Grep")
        #expect(args[allowedIdx + 3] == "Glob")
        #expect(args[allowedIdx + 4] == "WebFetch")
        #expect(args[allowedIdx + 5] == "WebSearch")
        #expect(args[allowedIdx + 6] == "Bash(gh:*)")
        #expect(!args.contains("--resume"))
    }

    @Test func resumeReadOnlyNoInputs() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            configuration: configuration(mode: .readOnly),
            inputs: nil,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--allowedTools"))
        #expect(args.contains("--resume"))
        #expect(!args.contains("--session-id"))
    }

    @Test func skillFilesRenderOneAppendSystemPromptFileEach() throws {
        let skillA = URL(fileURLWithPath: "/skills/grill-me.md")
        let skillB = URL(fileURLWithPath: "/skills/to-prd.md")
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write, skillFiles: [skillA, skillB]),
            inputs: nil,
            sessionId: sessionId
        )

        let flagCount = args.filter { $0 == "--append-system-prompt-file" }.count
        #expect(flagCount == 2)
        let firstIdx = args.firstIndex(of: "--append-system-prompt-file")!
        #expect(args[firstIdx + 1] == skillA.path)
        #expect(args.contains(skillB.path))
    }

    @Test func addDirsRenderMultipleAddDirAlongsideInputs() throws {
        let inputs = InputBundle(root: inputsRoot, relativePaths: ["a.txt"])
        let dir1 = URL(fileURLWithPath: "/skills/grill-me")
        let dir2 = URL(fileURLWithPath: "/extra")
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write, addDirs: [dir1, dir2]),
            inputs: inputs,
            sessionId: sessionId
        )

        let addDirValues = args.indices
            .filter { args[$0] == "--add-dir" }
            .map { args[$0 + 1] }
        #expect(addDirValues == [inputsRoot.path, dir1.path, dir2.path])
    }

    // MARK: - Setting sources

    /// The default: only the user's own settings load, so a repository's `.claude/` hooks and permissions
    /// stay out of an unattended run.
    @Test func untrustedRepositoryLoadsUserSettingSourcesOnly() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            sessionId: sessionId
        )

        let idx = try #require(args.firstIndex(of: "--setting-sources"))
        #expect(args[idx + 1] == "user")
    }

    /// The Workflow's opt-in restores the repository's own setting sources alongside the user's.
    @Test func trustedRepositoryLoadsProjectAndLocalSettingSources() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            trustsRepositorySettings: true,
            inputs: nil,
            sessionId: sessionId
        )

        let idx = try #require(args.firstIndex(of: "--setting-sources"))
        #expect(args[idx + 1] == "user,project,local")
    }

    /// Trust is a per-Turn input, not a Session pin, so it applies to a resume Turn exactly as it does to
    /// a start Turn — and changes nothing else about the rendered arguments.
    @Test func trustAffectsResumeTurnsAndNothingButSettingSources() throws {
        let untrusted = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            configuration: configuration(mode: .readOnly),
            inputs: nil,
            sessionId: sessionId
        )
        let trusted = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            configuration: configuration(mode: .readOnly),
            trustsRepositorySettings: true,
            inputs: nil,
            sessionId: sessionId
        )

        let idx = try #require(trusted.firstIndex(of: "--setting-sources"))
        #expect(trusted[idx + 1] == "user,project,local")
        #expect(untrusted[idx + 1] == "user")

        var expected = untrusted
        expected[idx + 1] = "user,project,local"
        #expect(trusted == expected)
    }

    // MARK: - StopFailure hook

    /// Every Turn with a scratch directory registers the hook: a settings file written into that
    /// directory and passed as `--settings`. The path is a fixed one so the snapshot of the arguments
    /// — the file name is keyed by turn id — is stable across machines.
    @Test func scratchRendersStopFailureHookSettingsFile() throws {
        let scratch = Harness.TurnScratch(
            directory: URL(fileURLWithPath: "/tmp/HarnessRenderArgsTests-hook"),
            turnID: turnID
        )
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            scratch: scratch,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        let idx = try #require(args.firstIndex(of: "--settings"))
        #expect(args[idx + 1] == "/tmp/HarnessRenderArgsTests-hook/\(turnID.uuidString).settings.json")
        #expect(FileManager.default.fileExists(atPath: args[idx + 1]))

        // The registered command drops the payload in the file this Turn's runner reads back.
        let written = try String(contentsOf: scratch.hookSettingsFile, encoding: .utf8)
        let expected = try StopFailureHook.settingsJSON(dropFile: scratch.stopFailureDropFile)
        #expect(written == String(decoding: expected, as: UTF8.self))
        #expect(written.contains(scratch.stopFailureDropFile.path))
    }

    /// Two Turns of one Session share the directory but not the files that must not be shared: a
    /// drop-file left behind by the first can't be read as the second's.
    @Test func eachTurnGetsItsOwnHookSettingsAndDropFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessRenderArgsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Harness.TurnScratch(directory: directory, turnID: UUID())
        let second = Harness.TurnScratch(directory: directory, turnID: UUID())

        #expect(first.hookSettingsFile != second.hookSettingsFile)
        #expect(first.stopFailureDropFile != second.stopFailureDropFile)
        #expect(first.mcpConfigFile == second.mcpConfigFile)
    }

    /// Rendering without a scratch directory leaves nowhere for the hook to drop a payload, so no hook
    /// is registered — the arguments are the ones this Harness rendered before the hook existed.
    @Test func noScratchRegistersNoHook() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            sessionId: sessionId
        )

        #expect(!args.contains("--settings"))
    }

    // MARK: - MCP servers

    /// A Turn scratch over a temp directory unique to a call; the directory is auto-created by
    /// `renderArgs` when it writes the Turn's config files into it.
    private func makeScratch() -> Harness.TurnScratch {
        Harness.TurnScratch(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("HarnessRenderArgsTests-\(UUID().uuidString)", isDirectory: true),
            turnID: turnID
        )
    }

    private var herculesServer: MCPServer {
        MCPServer(
            name: "hercules",
            command: "/path/to/Hercules",
            args: ["--mcp-issue-server", "--db", "/db/workflow.sqlite", "--workflow-id", "WF"],
            env: ["FOO": "bar"],
            tools: ["create_issue"]
        )
    }

    @Test func readOnlyWithMCPServerWritesConfigAndExtendsAllowlist() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .readOnly, mcpServers: [herculesServer]),
            inputs: nil,
            scratch: scratch,
            sessionId: sessionId
        )

        // --mcp-config points at the written path, and the file exists.
        #expect(args.contains("--mcp-config"))
        let configIdx = args.firstIndex(of: "--mcp-config")!
        let configPath = args[configIdx + 1]
        #expect(configPath == scratch.directory.appendingPathComponent("mcp-config.json").path)
        #expect(FileManager.default.fileExists(atPath: configPath))

        // The allowlist is the readOnly base plus the derived tool name(s), in order.
        let allowedIdx = args.firstIndex(of: "--allowedTools")!
        #expect(args[allowedIdx + 1] == "Read")
        #expect(args[allowedIdx + 2] == "Grep")
        #expect(args[allowedIdx + 3] == "Glob")
        #expect(args[allowedIdx + 4] == "WebFetch")
        #expect(args[allowedIdx + 5] == "WebSearch")
        #expect(args[allowedIdx + 6] == "Bash(gh:*)")
        #expect(args[allowedIdx + 7] == "mcp__hercules__create_issue")
    }

    @Test func resumeRepassesMCPConfig() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            configuration: configuration(mode: .readOnly, mcpServers: [herculesServer]),
            inputs: nil,
            scratch: scratch,
            sessionId: sessionId
        )

        #expect(args.contains("--resume"))
        #expect(args.contains("--mcp-config"))
        #expect(args.contains("mcp__hercules__create_issue"))
    }

    /// A resume Turn carrying a per-Turn override (the server set the override resolves to) renders
    /// with `--mcp-config` and the derived tool in `--allowedTools`, just as a pinned set would.
    @Test func resumeWithPerTurnOverrideRendersConfigAndAllowlistedTool() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            configuration: configuration(mode: .readOnly, mcpServers: [herculesServer]),
            inputs: nil,
            scratch: scratch,
            sessionId: sessionId
        )

        #expect(args.contains("--resume"))
        #expect(args.contains("--mcp-config"))

        let allowedIdx = try #require(args.firstIndex(of: "--allowedTools"))
        let allowed = args[(allowedIdx + 1)...]
        #expect(allowed.contains("mcp__hercules__create_issue"))
    }

    /// The override's absence (empty server set) leaves a resume Turn without `--mcp-config` or the
    /// derived tool — the fallback path behaves exactly like a plain resume.
    @Test func resumeWithoutOverrideRendersNoConfigAndNoAllowlistedTool() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            configuration: configuration(mode: .readOnly, mcpServers: []),
            inputs: nil,
            scratch: scratch,
            sessionId: sessionId
        )

        #expect(args.contains("--resume"))
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains("mcp__hercules__create_issue"))
    }

    @Test func writeModeWithMCPServerAllowlistsBashAndMCPTools() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write, mcpServers: [herculesServer]),
            inputs: nil,
            scratch: scratch,
            sessionId: sessionId
        )

        // The server is configured regardless of mode...
        #expect(args.contains("--mcp-config"))
        // ...and write mode allowlists Bash plus the MCP tools (acceptEdits won't auto-approve either).
        let allowedIdx = args.firstIndex(of: "--allowedTools")!
        #expect(args[allowedIdx + 1] == "Bash")
        #expect(args[allowedIdx + 2] == "mcp__hercules__create_issue")
    }

    /// No servers, no `--mcp-config` and no config file — only the hook settings every Turn writes are
    /// left in the scratch directory.
    @Test func noMCPServerLeavesArgsUnchanged() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .readOnly, mcpServers: []),
            inputs: nil,
            scratch: scratch,
            sessionId: sessionId
        )

        #expect(!args.contains("--mcp-config"))
        #expect(!FileManager.default.fileExists(atPath: scratch.mcpConfigFile.path))
        // The allowlist is the readOnly base and nothing after it — no derived tool names. Anchored to
        // the allowlist rather than to the end of `args`, which now carries the hook's `--settings`.
        let allowedIdx = args.firstIndex(of: "--allowedTools")!
        #expect(
            Array(args[(allowedIdx + 1)...(allowedIdx + 6)])
                == ["Read", "Grep", "Glob", "WebFetch", "WebSearch", "Bash(gh:*)"]
        )
        #expect(args[allowedIdx + 7] == "--settings")
    }

    @Test func mcpServerWithoutDataDirectoryThrows() {
        #expect(throws: AgentError.self) {
            try Harness.renderArgs(
                binary: binary,
                operation: .start,
                configuration: configuration(mode: .readOnly, mcpServers: [herculesServer]),
                inputs: nil,
                scratch: nil,
                sessionId: sessionId
            )
        }
    }

    @Test func mcpConfigJSONHasMCPServersShape() throws {
        let data = try Harness.mcpConfigJSON(servers: [herculesServer])
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let servers = root["mcpServers"] as! [String: Any]
        let hercules = servers["hercules"] as! [String: Any]

        #expect(hercules["command"] as? String == "/path/to/Hercules")
        #expect(hercules["args"] as? [String] == herculesServer.args)
        #expect(hercules["env"] as? [String: String] == ["FOO": "bar"])
    }

    @Test func qualifiedToolNamesAreNamespaced() {
        let server = MCPServer(name: "hercules", command: "x", tools: ["create_issue", "ask_user"])
        #expect(server.qualifiedToolNames == ["mcp__hercules__create_issue", "mcp__hercules__ask_user"])
    }

    // MARK: - Extra arguments

    @Test func extraArgumentsAppendAfterGeneratedArguments() throws {
        let inputs = InputBundle(root: inputsRoot, relativePaths: ["a.txt"])
        let skill = URL(fileURLWithPath: "/skills/grill-me.md")
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(
                mode: .write,
                skillFiles: [skill],
                addDirs: [URL(fileURLWithPath: "/extra")]
            ),
            inputs: inputs,
            extraArguments: [ExtraArgument(flag: "--model", value: "opus")],
            sessionId: sessionId
        )

        // The extras land after the last generated argument (the skill file's path).
        #expect(args.last == "opus")
        let modelIdx = args.firstIndex(of: "--model")!
        let skillIdx = args.firstIndex(of: skill.path)!
        #expect(modelIdx > skillIdx)
    }

    @Test func extraArgumentWithNilValueRendersBareFlag() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            extraArguments: [ExtraArgument(flag: "--debug")],
            sessionId: sessionId
        )

        #expect(args.last == "--debug")
        #expect(args.filter { $0 == "--debug" }.count == 1)
    }

    @Test func extraArgumentWithEmptyValueRendersBareFlag() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            extraArguments: [ExtraArgument(flag: "--debug", value: "")],
            sessionId: sessionId
        )

        #expect(args.last == "--debug")
    }

    @Test func extraArgumentWithValueRendersFlagThenValue() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            extraArguments: [ExtraArgument(flag: "--model", value: "opus")],
            sessionId: sessionId
        )

        let idx = args.firstIndex(of: "--model")!
        #expect(args[idx + 1] == "opus")
    }

    @Test func emptyExtraArgumentsLeaveOutputByteIdentical() throws {
        let make: ([ExtraArgument]) throws -> [String] = { extras in
            try Harness.renderArgs(
                binary: self.binary,
                operation: .start,
                configuration: self.configuration(mode: .write),
                inputs: nil,
                extraArguments: extras,
                sessionId: self.sessionId
            )
        }

        let baseline = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            sessionId: sessionId
        )
        #expect(try make([]) == baseline)
    }

    @Test func whitespaceOnlyFlagsAreSkippedAndOrderPreserved() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            configuration: configuration(mode: .write),
            inputs: nil,
            extraArguments: [
                ExtraArgument(flag: "--first", value: "1"),
                ExtraArgument(flag: "   "),
                ExtraArgument(flag: "", value: "ignored"),
                ExtraArgument(flag: "--last"),
            ],
            sessionId: sessionId
        )

        let tail = Array(args.suffix(3))
        #expect(tail == ["--first", "1", "--last"])
    }
}

@Suite("Harness.SessionConfiguration")
struct HarnessSessionConfigurationTests {
    let worktree = URL(fileURLWithPath: "/tmp/wt")
    let skill = URL(fileURLWithPath: "/skills/grill-me.md")
    let addDir = URL(fileURLWithPath: "/skills/grill-me")
    let pinnedServer = MCPServer(name: "hercules", command: "/path/to/Hercules", tools: ["create_issue"])

    @Test func fromSessionCarriesEveryPin() {
        let session = Session(
            id: Session.ID(rawValue: UUID()),
            worktree: worktree,
            mode: .readOnly,
            kind: .design,
            skillFiles: [skill],
            addDirs: [addDir],
            mcpServers: [pinnedServer]
        )

        let configuration = Harness.SessionConfiguration(session: session)

        #expect(configuration.worktree == worktree)
        #expect(configuration.mode == .readOnly)
        #expect(configuration.skillFiles == [skill])
        #expect(configuration.addDirs == [addDir])
        #expect(configuration.mcpServers == [pinnedServer])
    }

    /// A resume Turn's override replaces the pinned servers for that Turn only (ADR 0001); the Session
    /// itself is untouched, so the next Turn without an override sees the pins again.
    @Test func perTurnMCPOverrideReplacesPinnedServers() {
        let session = Session(
            id: Session.ID(rawValue: UUID()),
            worktree: worktree,
            mode: .write,
            kind: .execute,
            mcpServers: [pinnedServer]
        )
        let override = MCPServer(name: "other", command: "/other", tools: ["ask_user"])

        #expect(Harness.SessionConfiguration(session: session, mcpServers: [override]).mcpServers == [override])
        #expect(Harness.SessionConfiguration(session: session, mcpServers: []).mcpServers == [])
        #expect(Harness.SessionConfiguration(session: session, mcpServers: nil).mcpServers == [pinnedServer])
    }

    @Test func fromStartRequestCarriesEveryPin() throws {
        let (database, workflowID, root) = try WorkflowFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let request = StartRequest(
            prompt: "hello",
            worktree: worktree,
            mode: .readOnly,
            database: database,
            workflowID: workflowID,
            kind: .design,
            skillFiles: [skill],
            addDirs: [addDir],
            mcpServers: [pinnedServer]
        )

        let configuration = Harness.SessionConfiguration(request: request)

        #expect(configuration.worktree == worktree)
        #expect(configuration.mode == .readOnly)
        #expect(configuration.skillFiles == [skill])
        #expect(configuration.addDirs == [addDir])
        #expect(configuration.mcpServers == [pinnedServer])
    }
}
