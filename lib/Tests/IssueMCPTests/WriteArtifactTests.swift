import Foundation
import MCP
import Testing

@testable import IssueMCP

@Suite("WriteArtifact")
struct WriteArtifactTests {

    // MARK: - The file-write seam

    @Test func writesMarkdownToPathCreatingIntermediateDirectories() throws {
        let directory = Self.temporaryDirectory()
        // A path several levels deep that doesn't exist yet, mirroring `phases/design/summary.md`.
        let path = directory.appendingPathComponent("phases/design/summary.md").path

        try writeArtifact(WriteArtifactArguments(markdown: "# Design\n\nThe plan."), to: path)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# Design\n\nThe plan.")
    }

    @Test func overwritesAnExistingFile() throws {
        let directory = Self.temporaryDirectory()
        let path = directory.appendingPathComponent("phases/prd/prd.md").path

        try writeArtifact(WriteArtifactArguments(markdown: "# First"), to: path)
        try writeArtifact(WriteArtifactArguments(markdown: "# Second"), to: path)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# Second")
    }

    @Test func ignoresAnyPathInArguments() throws {
        // `markdown` is the only decoded field, so an extra key in the raw arguments can't override the
        // launch path.
        let directory = Self.temporaryDirectory()
        let launchPath = directory.appendingPathComponent("summary.md").path
        let arguments = try WriteArtifactArguments(mcpArguments: [
            "markdown": .string("body"),
            "path": .string(directory.appendingPathComponent("elsewhere.md").path),
        ])

        try writeArtifact(arguments, to: launchPath)

        #expect(FileManager.default.fileExists(atPath: launchPath))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("elsewhere.md").path))
    }

    // MARK: - Argument decoding

    @Test func decodesArgumentsFromMCPValues() throws {
        let arguments = try WriteArtifactArguments(mcpArguments: ["markdown": .string("# Doc")])
        #expect(arguments == WriteArtifactArguments(markdown: "# Doc"))
    }

    @Test func malformedArgumentsThrow() {
        // Missing the required `markdown` field.
        #expect(throws: (any Error).self) {
            try WriteArtifactArguments(mcpArguments: [:])
        }
        // Wrong type for `markdown`.
        #expect(throws: (any Error).self) {
            try WriteArtifactArguments(mcpArguments: ["markdown": .int(3)])
        }
        // No arguments at all.
        #expect(throws: (any Error).self) {
            try WriteArtifactArguments(mcpArguments: nil)
        }
    }

    // MARK: - Launch argument parsing

    @Test func parsesSubcommandArguments() {
        let config = ArtifactMCPLaunch.parse([
            "/path/to/Hercules", "--mcp-artifact-server",
            "--artifact-path", "/tmp/wf/phases/design/summary.md",
        ])
        #expect(config == ArtifactMCPLaunch.Configuration(
            artifactPath: "/tmp/wf/phases/design/summary.md"
        ))
    }

    @Test func returnsNilWithoutSubcommand() {
        #expect(ArtifactMCPLaunch.parse(["/path/to/Hercules"]) == nil)
        // The path operand alone, without the subcommand, is not the artifact server.
        #expect(ArtifactMCPLaunch.parse([
            "/path/to/Hercules", "--artifact-path", "/tmp/wf/phases/design/summary.md",
        ]) == nil)
    }

    @Test func returnsNilWhenPathOperandMissing() {
        #expect(ArtifactMCPLaunch.parse(["--mcp-artifact-server"]) == nil)
        // Flag present but no following value.
        #expect(ArtifactMCPLaunch.parse(["--mcp-artifact-server", "--artifact-path"]) == nil)
    }

    // MARK: - Helpers

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteArtifactTests-\(UUID().uuidString)", isDirectory: true)
    }
}
