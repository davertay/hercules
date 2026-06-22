/// The statuses the Execute orchestrator writes onto an Issue as it runs; raw values persist in
/// `IssueRow.status`. The write vocabulary only — the initial `"new"` is written by the create-issue
/// tool, and the read-side `IssueGraph.IssueStatus` is a separate, richer concern.
public enum IssueRunStatus: String, Codable, Sendable, CaseIterable {
    case inProgress = "in_progress"
    case done
    case failed
}
