import Foundation
import Store

/// The value a `WorkflowContainer` window is keyed on: the Workflow's id plus the on-disk
/// location of its directory and the repo it operates against. Carries the Workflow's fixed ``mode``
/// (set at creation, read from the `workflow` row when reopening) so the window can pick its Phase
/// topology without a synchronous database read — which test/preview contexts can't satisfy, since
/// they don't honour the on-disk path.
public struct WorkflowWindowData: Codable, Hashable, Sendable {
    public let id: UUID
    public let directory: URL
    public let repoPath: String
    public let mode: WorkflowMode

    public init(id: UUID, directory: URL, repoPath: String, mode: WorkflowMode = .standard) {
        self.id = id
        self.directory = directory
        self.repoPath = repoPath
        self.mode = mode
    }
}
