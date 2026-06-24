import CustomDump
import Foundation
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

    @Test func startWriteNoInputs() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .write,
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
        #expect(!args.contains("--allowedTools"))
        #expect(!args.contains("--mcp-config"))
    }

    @Test func startWriteWithInputs() throws {
        let inputs = InputBundle(root: inputsRoot, relativePaths: ["a.txt", "b.md"])
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .write,
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
        #expect(!args.contains("--allowedTools"))
    }

    @Test func resumeReadOnlyWithInputs() throws {
        let inputs = InputBundle(root: inputsRoot, relativePaths: ["c.swift"])
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            worktree: worktree,
            mode: .readOnly,
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
            worktree: worktree,
            mode: .write,
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
            worktree: worktree,
            mode: .write,
            inputs: nil,
            sessionId: sessionId
        )
        #expect(!startArgs.contains("--resume"))
    }

    @Test func startReadOnlyNoInputs() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .readOnly,
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
        #expect(!args.contains("--resume"))
    }

    @Test func resumeReadOnlyNoInputs() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            worktree: worktree,
            mode: .readOnly,
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
            worktree: worktree,
            mode: .write,
            inputs: nil,
            skillFiles: [skillA, skillB],
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
            worktree: worktree,
            mode: .write,
            inputs: inputs,
            addDirs: [dir1, dir2],
            sessionId: sessionId
        )

        let addDirValues = args.indices
            .filter { args[$0] == "--add-dir" }
            .map { args[$0 + 1] }
        #expect(addDirValues == [inputsRoot.path, dir1.path, dir2.path])
    }

    // MARK: - MCP servers

    /// A temp directory unique to a call; auto-created by `renderArgs` when it writes the config.
    private func makeSessionDataDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessRenderArgsTests-\(UUID().uuidString)", isDirectory: true)
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
        let dataDir = makeSessionDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .readOnly,
            inputs: nil,
            mcpServers: [herculesServer],
            sessionDataDirectory: dataDir,
            sessionId: sessionId
        )

        // --mcp-config points at the written path, and the file exists.
        #expect(args.contains("--mcp-config"))
        let configIdx = args.firstIndex(of: "--mcp-config")!
        let configPath = args[configIdx + 1]
        #expect(configPath == dataDir.appendingPathComponent("mcp-config.json").path)
        #expect(FileManager.default.fileExists(atPath: configPath))

        // The allowlist is the readOnly base plus the derived tool name(s), in order.
        let allowedIdx = args.firstIndex(of: "--allowedTools")!
        #expect(args[allowedIdx + 1] == "Read")
        #expect(args[allowedIdx + 2] == "Grep")
        #expect(args[allowedIdx + 3] == "Glob")
        #expect(args[allowedIdx + 4] == "WebFetch")
        #expect(args[allowedIdx + 5] == "WebSearch")
        #expect(args[allowedIdx + 6] == "mcp__hercules__create_issue")
    }

    @Test func resumeRepassesMCPConfig() throws {
        let dataDir = makeSessionDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            worktree: worktree,
            mode: .readOnly,
            inputs: nil,
            mcpServers: [herculesServer],
            sessionDataDirectory: dataDir,
            sessionId: sessionId
        )

        #expect(args.contains("--resume"))
        #expect(args.contains("--mcp-config"))
        #expect(args.contains("mcp__hercules__create_issue"))
    }

    /// A resume Turn carrying a per-Turn override (the server set the override resolves to) renders
    /// with `--mcp-config` and the derived tool in `--allowedTools`, just as a pinned set would.
    @Test func resumeWithPerTurnOverrideRendersConfigAndAllowlistedTool() throws {
        let dataDir = makeSessionDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            worktree: worktree,
            mode: .readOnly,
            inputs: nil,
            mcpServers: [herculesServer],
            sessionDataDirectory: dataDir,
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
        let dataDir = makeSessionDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .resume,
            worktree: worktree,
            mode: .readOnly,
            inputs: nil,
            mcpServers: [],
            sessionDataDirectory: dataDir,
            sessionId: sessionId
        )

        #expect(args.contains("--resume"))
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains("mcp__hercules__create_issue"))
    }

    @Test func writeModeWithMCPServerConfiguresButDoesNotAddAllowlist() throws {
        let dataDir = makeSessionDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .write,
            inputs: nil,
            mcpServers: [herculesServer],
            sessionDataDirectory: dataDir,
            sessionId: sessionId
        )

        // The server is configured regardless of mode...
        #expect(args.contains("--mcp-config"))
        // ...but write mode has no allowlist to extend.
        #expect(!args.contains("--allowedTools"))
    }

    @Test func noMCPServerLeavesArgsUnchanged() throws {
        let dataDir = makeSessionDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .readOnly,
            inputs: nil,
            mcpServers: [],
            sessionDataDirectory: dataDir,
            sessionId: sessionId
        )

        #expect(!args.contains("--mcp-config"))
        #expect(!FileManager.default.fileExists(atPath: dataDir.path))
        let allowedIdx = args.firstIndex(of: "--allowedTools")!
        #expect(args[allowedIdx + 1] == "Read")
        #expect(args.last == "WebSearch")
    }

    @Test func mcpServerWithoutDataDirectoryThrows() {
        #expect(throws: AgentError.self) {
            try Harness.renderArgs(
                binary: binary,
                operation: .start,
                worktree: worktree,
                mode: .readOnly,
                inputs: nil,
                mcpServers: [herculesServer],
                sessionDataDirectory: nil,
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
            worktree: worktree,
            mode: .write,
            inputs: inputs,
            skillFiles: [skill],
            addDirs: [URL(fileURLWithPath: "/extra")],
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
            worktree: worktree,
            mode: .write,
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
            worktree: worktree,
            mode: .write,
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
            worktree: worktree,
            mode: .write,
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
                worktree: self.worktree,
                mode: .write,
                inputs: nil,
                extraArguments: extras,
                sessionId: self.sessionId
            )
        }

        let baseline = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .write,
            inputs: nil,
            sessionId: sessionId
        )
        #expect(try make([]) == baseline)
    }

    @Test func whitespaceOnlyFlagsAreSkippedAndOrderPreserved() throws {
        let args = try Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .write,
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
