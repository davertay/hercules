import Design
import Dependencies
import Foundation
import Observation
import SQLiteData
import Store

@MainActor
@Observable
public final class WorkflowContainerModel {
    public let id: UUID
    public let directory: URL
    public let repoPath: String

    /// The per-Workflow Store, opened once for the window's lifetime so the Phases can observe it.
    @ObservationIgnored
    let database: (any DatabaseWriter)?

    /// The Design Phase's chat, scoped to observe this Workflow's database. `nil` only if the Store
    /// could not be opened.
    @ObservationIgnored
    public let designModel: DesignModel?

    public init(data: WorkflowWindowData) {
        id = data.id
        directory = data.directory
        repoPath = data.repoPath

        let database = try? openWorkflowDatabase(at: data.directory)
        self.database = database
        if let database {
            // Scope `defaultDatabase` so the model's `@Fetch` observes this Workflow's Store rather
            // than the app-wide default.
            designModel = withDependencies {
                $0.defaultDatabase = database
            } operation: {
                DesignModel(
                    worktree: URL(fileURLWithPath: data.repoPath),
                    workflowID: data.id,
                    workflowDirectory: data.directory,
                    database: database
                )
            }
        } else {
            designModel = nil
        }
    }

    var title: String {
        repoPath.isEmpty ? "Workflow" : URL(fileURLWithPath: repoPath).lastPathComponent
    }
}
