/// The lifecycle statuses the Execute orchestrator writes onto an Issue as it runs (ADR-style: the
/// orchestrator owns these writes directly, not through the MCP write tool). The raw values are the
/// strings persisted in `IssueRow.status`.
///
/// This is the **write** vocabulary only. The initial `"new"` (meaning pending) is written by the
/// Allocate Phase's create-issue tool, never by the orchestrator, so it is not a case here. The
/// presentation layer's richer `IssueGraph.IssueStatus` (which also derives `ready` from the graph and
/// reserves `skipped`) is a separate, read-side concern.
public enum IssueRunStatus: String, Codable, Sendable, CaseIterable {
    /// An agent is actively working the Issue.
    case inProgress = "in_progress"
    /// The Issue landed successfully (the agent's Turn finished without error).
    case done
    /// The Issue's agent finished unsuccessfully.
    case failed
}
