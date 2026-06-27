import Foundation
import SQLiteData
import Store

public struct StartRequest: Sendable {
    public let prompt: String
    public let worktree: URL
    public let mode: AgentMode
    public let inputs: InputBundle?
    /// The Turn's rows are projected into this live as the Harness streams (ADR 0003).
    public let database: any DatabaseWriter
    public let workflowID: UUID
    public let kind: SessionKind
    /// Pre-generated so the caller can forward-link the Session before the run starts (Validate writes
    /// `review.sessionID` up front so its card's activity updates live); `nil` mints a fresh id.
    public let sessionID: UUID?
    /// Set only for `execute`-kind runs, so the Issue's transcript is recoverable; `nil` for chat.
    public let issueNumber: Int?
    /// Rendered as one `--append-system-prompt-file` each (ADR 0004); re-passed on every resume Turn.
    public let skillFiles: [URL]
    /// Exposed to the Harness via `--add-dir`, alongside any `InputBundle`.
    public let addDirs: [URL]
    public let mcpServers: [MCPServer]

    public init(
        prompt: String,
        worktree: URL,
        mode: AgentMode,
        inputs: InputBundle? = nil,
        database: any DatabaseWriter,
        workflowID: UUID,
        kind: SessionKind,
        sessionID: UUID? = nil,
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
        self.sessionID = sessionID
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
    public let database: any DatabaseWriter
    /// Overrides the Session's pinned servers for this single resume Turn only — no Session mutation.
    /// `nil` falls back to `session.mcpServers`, so existing callers behave unchanged (ADR 0001).
    public let mcpServers: [MCPServer]?

    public init(
        prompt: String,
        session: Session,
        inputs: InputBundle? = nil,
        database: any DatabaseWriter,
        mcpServers: [MCPServer]? = nil
    ) {
        self.prompt = prompt
        self.session = session
        self.inputs = inputs
        self.database = database
        self.mcpServers = mcpServers
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
