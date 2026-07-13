import Foundation

/// The value a `WorkflowContainer` window is keyed on: the Workflow's id plus the on-disk
/// location of its directory and the repo it operates against.
public struct WorkflowWindowData: Codable, Hashable, Sendable {
    public let id: UUID
    public let directory: URL
    public let repoPath: String

    public init(id: UUID, directory: URL, repoPath: String) {
        self.id = id
        self.directory = directory
        self.repoPath = repoPath
    }
}
