/// Presentation-level lifecycle status for an Issue node in a DAG view. Not persisted: `IssueRow.status`
/// stays a free `String` that the Execute Phase maps onto this enum, deriving `.ready` from the graph.
public enum IssueStatus: CaseIterable, Equatable, Hashable, Sendable {
    /// Not yet startable — dependencies outstanding. The stored `"new"` maps here.
    case pending
    /// Dependencies all satisfied. Derived from the graph, not stored.
    case ready
    case inProgress
    case done
    case failed
    /// Marked terminally complete without being worked.
    case skipped
    /// A HITL fix proposed by a Validate Persona, awaiting human approval before it can run. The stored
    /// `"proposed"` maps here, overriding the vacuous-ready derivation so it stays visually distinct.
    case proposed
}
