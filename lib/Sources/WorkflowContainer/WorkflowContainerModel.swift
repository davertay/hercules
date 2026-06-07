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

    /// Live view of this Workflow's completed `phase` rows, used to gate the sidebar. A Phase is
    /// unlocked once the Phase before it appears here, so completing Design unlocks PRD reactively —
    /// its `phase` row flips to complete and this observation re-fires without any manual refresh.
    @ObservationIgnored
    @Fetch var completedPhases: [PhaseRow] = []

    public init(data: WorkflowWindowData) {
        id = data.id
        directory = data.directory
        repoPath = data.repoPath

        let database = try? openWorkflowDatabase(at: data.directory)
        self.database = database
        if let database {
            // Scope `defaultDatabase` so the model's fetches observe this Workflow's Store rather
            // than the app-wide default; both fetches capture it for the window's lifetime.
            let (model, phases): (DesignModel, Fetch<[PhaseRow]>) = withDependencies {
                $0.defaultDatabase = database
            } operation: {
                let model = DesignModel(
                    worktree: URL(fileURLWithPath: data.repoPath),
                    workflowID: data.id,
                    workflowDirectory: data.directory,
                    database: database
                )
                let phases = Fetch(
                    wrappedValue: [],
                    CompletedPhasesRequest(workflowID: data.id),
                    animation: .default
                )
                return (model, phases)
            }
            designModel = model
            _completedPhases = phases
        } else {
            designModel = nil
            _completedPhases = Fetch(wrappedValue: [])
        }
    }

    /// Whether `phase` should open its real detail view rather than a locked placeholder. The first
    /// Phase is always unlocked; every other Phase unlocks once the Phase it consumes has completed.
    public func isUnlocked(_ phase: Phase) -> Bool {
        guard let predecessor = phase.predecessor else { return true }
        return completedPhases.contains { $0.kind == predecessor.rawValue }
    }

    var title: String {
        repoPath.isEmpty ? "Workflow" : URL(fileURLWithPath: repoPath).lastPathComponent
    }
}

/// Fetches a Workflow's completed, non-deleted `phase` rows. Driving the sidebar's gating off this
/// observation means a Phase flipping to complete re-fires it and unlocks the next Phase live.
struct CompletedPhasesRequest: FetchKeyRequest {
    let workflowID: UUID

    func fetch(_ db: Database) throws -> [PhaseRow] {
        try PhaseRow
            .where { $0.workflowID.eq(workflowID) }
            .where { $0.status.eq("complete") }
            .where { !$0.isDeleted }
            .fetchAll(db)
    }
}
