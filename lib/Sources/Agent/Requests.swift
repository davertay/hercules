import Foundation
import SQLiteData
import Store

public struct StartRequest: Sendable {
    public let prompt: String
    public let worktree: URL
    public let mode: AgentMode
    public let inputs: InputBundle?
    /// Handle to the Workflow's Store; the Turn's `session`/`turn`/`content_block` rows are
    /// projected into it live as the Harness streams (ADR 0003).
    public let database: any DatabaseWriter
    /// The Workflow the new Session belongs to. Referenced by the `session` row's foreign key.
    public let workflowID: UUID
    /// The surface the new Session serves; persisted on the `session` row to scope its Turns (ADR 0005).
    public let kind: SessionKind
    /// The Issue this Session works, set only for `execute`-kind runs; persisted on the `session` row
    /// so the Issue's transcript is recoverable. `nil` for every chat surface.
    public let issueNumber: Int?
    /// Skill prompt files rendered as one `--append-system-prompt-file` each (ADR 0004); pinned on
    /// the Session and re-passed on every resume Turn.
    public let skillFiles: [URL]
    /// Extra directories exposed to the Harness via `--add-dir`, alongside any `InputBundle`.
    public let addDirs: [URL]
    /// Custom MCP servers for the new Session; pinned on the `Session` and re-passed on every resume
    /// Turn, exactly as `skillFiles`/`addDirs` are (ADR 0001 / ADR 0004).
    public let mcpServers: [MCPServer]

    public init(
        prompt: String,
        worktree: URL,
        mode: AgentMode,
        inputs: InputBundle? = nil,
        database: any DatabaseWriter,
        workflowID: UUID,
        kind: SessionKind,
        issueNumber: Int? = nil,
        skillFiles: [URL] = [],
        addDirs: [URL] = [],
        mcpServers: [MCPServer] = []
    ) {
        self.prompt = prompt
        self.worktree = worktree
        self.mode = mode
        self.inputs = inputs
        self.database = database
        self.workflowID = workflowID
        self.kind = kind
        self.issueNumber = issueNumber
        self.skillFiles = skillFiles
        self.addDirs = addDirs
        self.mcpServers = mcpServers
    }
}

public struct SendRequest: Sendable {
    public let prompt: String
    public let session: Session
    public let inputs: InputBundle?
    /// Handle to the Workflow's Store the resumed Turn projects into.
    public let database: any DatabaseWriter

    public init(prompt: String, session: Session, inputs: InputBundle? = nil, database: any DatabaseWriter) {
        self.prompt = prompt
        self.session = session
        self.inputs = inputs
        self.database = database
    }
}

public struct InputBundle: Sendable {
    public let root: URL
    public let relativePaths: [String]

    public init(root: URL, relativePaths: [String]) {
        self.root = root
        self.relativePaths = relativePaths
    }
}
