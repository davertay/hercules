extension IssueRow {
    /// The status vocabulary persisted in `status` (statuses store as strings, ADR 0007) — the one home
    /// for every stored value: the create-issue tool stamps ``new``, Validate's HITL proposals stamp
    /// ``proposed``, and the Execute orchestrator writes the run lifecycle (``inProgress``, ``done``,
    /// ``failed``). The read-side `IssueGraph.IssueStatus` stays a separate, richer presentation concern,
    /// derived from these values plus the dependency graph.
    public enum Status: String, Codable, Sendable, CaseIterable {
        case new
        case inProgress = "in_progress"
        case done
        case failed
        case proposed
    }

    /// The persisted status parsed into the vocabulary, or `nil` for an unrecognised stored string.
    public var statusValue: Status? { Status(rawValue: status) }
}
