/// Presentation-level lifecycle status for a single Issue node in a DAG view.
///
/// This is the modernised port of the prior prototype's `TicketStatus` (`green` renamed to `done`).
/// It is **not** persisted: `Store`'s `IssueRow.status` stays a free `String`. A consumer (the
/// Execute Phase) maps the raw stored string onto this enum when building `DAGNode`s, deriving
/// `.ready` from the dependency graph rather than reading it from storage.
public enum IssueStatus: CaseIterable, Equatable, Hashable, Sendable {
    /// Not yet startable — one or more dependencies are still outstanding. The raw stored `"new"`
    /// status maps here.
    case pending
    /// Dependencies all satisfied; the Issue is the next eligible to be worked. Derived from the
    /// graph (all deps `done`), not stored.
    case ready
    /// An agent is actively working the Issue.
    case inProgress
    /// The Issue landed successfully.
    case done
    /// The Issue's agent finished unsuccessfully.
    case failed
    /// The Issue was marked terminally complete without being worked.
    case skipped
}
