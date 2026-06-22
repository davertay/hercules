/// The persistence-agnostic shape a DAG view renders one Issue as, decoupling `DAGGraphUI` and the
/// graph algorithms from the `Store` schema. `dependencies` lists the `number`s this Issue depends on.
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
