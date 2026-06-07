import Foundation
import Observation

@MainActor
@Observable
public final class WorkflowContainerModel {
    public let id: UUID
    public let directory: URL
    public let repoPath: String

    public init(data: WorkflowWindowData) {
        id = data.id
        directory = data.directory
        repoPath = data.repoPath
    }

    var title: String {
        repoPath.isEmpty ? "Workflow" : URL(fileURLWithPath: repoPath).lastPathComponent
    }
}
