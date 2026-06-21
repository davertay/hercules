import Allocate
import Design
import Dependencies
import Execute
import Foundation
import Observation
import PRD
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

    /// The PRD Phase's directed one-shot surface, constructed eagerly alongside Design and scoped to
    /// the same Workflow database with the PRD Session kind. `nil` only if the Store could not be
    /// opened.
    @ObservationIgnored
    public let prdModel: PRDModel?

    /// The Allocate Phase's hybrid surface, constructed eagerly alongside Design and PRD and scoped to
    /// the same Workflow database with the Allocate Session kind. Its create-issue MCP server is the
    /// app binary re-executed, so the command is `Bundle.main.executableURL`. `nil` only if the Store
    /// could not be opened.
    @ObservationIgnored
    public let allocateModel: AllocateModel?

    /// The Execute Phase's DAG visualization, constructed eagerly alongside the other Phase models and
    /// scoped to the same Workflow database with the same observation seam. `nil` only if the Store
    /// could not be opened.
    @ObservationIgnored
    public let executeModel: ExecuteModel?

    /// Live view of this Workflow's completed `phase` rows, used to gate the sidebar. A Phase is
    /// unlocked once the Phase before it appears here, so completing Design unlocks PRD reactively —
    /// its `phase` row flips to complete and this observation re-fires without any manual refresh.
    @ObservationIgnored
    @Fetch var completedPhases: [PhaseRow] = []

    public init(data: WorkflowWindowData) {
        id = data.id
        directory = data.directory
        repoPath = data.repoPath

        // Every Phase operates in the Workflow's git worktree — the deterministic `worktree/`
        // subdirectory created eagerly at Workflow creation — rather than the user's raw checkout. The
        // path is a pure convention derived from the directory, so a state-restored reopen recomputes it
        // and reads the already-existing on-disk worktree without ever re-creating it.
        let worktree = workflowWorktree(in: data.directory)

        let database = try? openWorkflowDatabase(at: data.directory)
        self.database = database
        if let database {
            // Scope `defaultDatabase` so the model's fetches observe this Workflow's Store rather
            // than the app-wide default; both fetches capture it for the window's lifetime.
            let (model, prd, allocate, execute, phases): (DesignModel, PRDModel, AllocateModel, ExecuteModel, Fetch<[PhaseRow]>) = withDependencies {
                $0.defaultDatabase = database
            } operation: {
                let model = DesignModel(
                    worktree: worktree,
                    workflowID: data.id,
                    workflowDirectory: data.directory,
                    database: database
                )
                let prd = PRDModel(
                    worktree: worktree,
                    workflowID: data.id,
                    workflowDirectory: data.directory,
                    database: database
                )
                let allocate = AllocateModel(
                    worktree: worktree,
                    workflowID: data.id,
                    workflowDirectory: data.directory,
                    mcpServerCommand: Self.mcpServerCommand,
                    database: database
                )
                let execute = ExecuteModel(workflowID: data.id, database: database, worktree: worktree)
                let phases = Fetch(
                    wrappedValue: [],
                    CompletedPhasesRequest(workflowID: data.id),
                    animation: .default
                )
                return (model, prd, allocate, execute, phases)
            }
            designModel = model
            prdModel = prd
            allocateModel = allocate
            executeModel = execute
            _completedPhases = phases
        } else {
            designModel = nil
            prdModel = nil
            allocateModel = nil
            executeModel = nil
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

    /// The command the Allocate Phase's create-issue MCP server is spawned as: the running app binary
    /// re-executed (it branches into the stdio server at `@main` before AppKit boots). Per ADR 0006
    /// no separate helper binary is embedded, so the path is the app's own executable.
    private static var mcpServerCommand: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
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
