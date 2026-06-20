/// The persistence-agnostic shape a DAG view renders one Issue as.
///
/// Decouples the view layer (`DAGGraphUI`) from the persistence layer (`Store`/SQLite): a feature
/// module maps each `IssueRow` to a `DAGNode`, so `DAGGraphUI` and the graph algorithms here depend
/// only on this value type, not on the database schema.
///
/// `dependencies` lists the `number`s of the other Issues this one depends on — the same per-Workflow
/// 1…N numbering carried on `IssueRow.number` / `IssueRow.dependencies`.
public struct DAGNode: Identifiable, Equatable, Hashable, Sendable {
    public let number: Int
    public let title: String
    public let status: IssueStatus
    public let dependencies: [Int]

    public var id: Int { number }

    public init(number: Int, title: String, status: IssueStatus, dependencies: [Int]) {
        self.number = number
        self.title = title
        self.status = status
        self.dependencies = dependencies
    }
}
