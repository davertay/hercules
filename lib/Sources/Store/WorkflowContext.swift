import Foundation
import SQLiteData

/// Everything a Phase model needs to operate on one Workflow — built once by the container and handed
/// to all four Phase models, instead of five loose parameters travelling together.
public struct WorkflowContext {
    public let workflowID: UUID
    /// The per-Workflow Store every Phase observes and writes.
    public let database: any DatabaseWriter
    /// The Workflow's git worktree the agents run in.
    public let worktree: URL
    /// The Workflow directory its Artifacts are written beneath.
    public let workflowDirectory: URL
    /// The app binary, re-executed as the stdio MCP servers (ADR 0006).
    public let mcpServerCommand: String

    public init(
        workflowID: UUID,
        database: any DatabaseWriter,
        worktree: URL,
        workflowDirectory: URL,
        mcpServerCommand: String
    ) {
        self.workflowID = workflowID
        self.database = database
        self.worktree = worktree
        self.workflowDirectory = workflowDirectory
        self.mcpServerCommand = mcpServerCommand
    }
}
