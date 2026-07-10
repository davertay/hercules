import Foundation
import MCP

// The seam below the MCP transport, driven directly by tests without real stdio.

/// The Harness allowlist entry is the qualified `mcp__hercules__write_artifact`.
public let writeArtifactToolName = "write_artifact"

/// The `write_artifact` tool's arguments: the model supplies only the markdown content. The destination
/// path is fixed by the host launch argument (ADR 0006), never a tool argument, so a call can't redirect
/// the write.
public struct WriteArtifactArguments: Codable, Equatable, Sendable {
    public var markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }

    private enum CodingKeys: String, CodingKey {
        case markdown
    }

    /// Throws when the required field is missing or the wrong type — reported back as a tool error.
    public init(mcpArguments: [String: Value]?) throws {
        let data = try JSONEncoder().encode(Value.object(mcpArguments ?? [:]))
        self = try JSONDecoder().decode(WriteArtifactArguments.self, from: data)
    }
}

/// Writes a Phase's markdown Artifact to the host-fixed `path`, creating intermediate directories. This
/// is the first MCP writer to touch the filesystem rather than the Store (ADR 0006): it needs no DB, just
/// the destination. `path` comes from the launch context, not the arguments, so the model can't target
/// another file.
public func writeArtifact(_ arguments: WriteArtifactArguments, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try arguments.markdown.write(to: url, atomically: true, encoding: .utf8)
}
