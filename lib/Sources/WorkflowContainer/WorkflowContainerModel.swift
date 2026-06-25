import Allocate
import Design
import Dependencies
import Execute
import Foundation
import Observation
import PRD
import SQLiteData
import Store
import Validate

@MainActor
@Observable
public final class WorkflowContainerModel {
    public let id: UUID
    public let directory: URL
    public let repoPath: String

    /// The per-Workflow Store, opened once for the window's lifetime so the Phases can observe it.
    @ObservationIgnored
    let database: (any DatabaseWriter)?

    /// Each Phase model is `nil` only if the Store could not be opened.
    @ObservationIgnored
    public let designModel: DesignModel?

    @ObservationIgnored
    public let prdModel: PRDModel?

    @ObservationIgnored
    public let allocateModel: AllocateModel?

    @ObservationIgnored
    public let executeModel: ExecuteModel?

    @ObservationIgnored
    public let validateModel: ValidateModel?

    /// Gates the sidebar: a Phase unlocks once the Phase before it appears here, so completing one
    /// re-fires this observation and unlocks the next without any manual refresh.
    @ObservationIgnored
    @Fetch var completedPhases: [PhaseRow] = []

    /// The Workflow's own row, observed so an edit to its `title` flows live to the window title bar,
    /// the sidebar, and the settings sheet.
    @ObservationIgnored
    @Fetch var workflowRow: WorkflowRow?

    public init(data: WorkflowWindowData) {
        id = data.id
        directory = data.directory
        repoPath = data.repoPath

        // The worktree path is a pure convention derived from the directory, so a state-restored reopen
        // recomputes it and reads the already-existing on-disk worktree without re-creating it.
        let worktree = workflowWorktree(in: data.directory)

        let database = try? openWorkflowDatabase(at: data.directory)
        self.database = database
        if let database {
            // Scope `defaultDatabase` so the models' fetches observe this Workflow's Store.
            let (model, prd, allocate, execute, validate, phases, row): (DesignModel, PRDModel, AllocateModel, ExecuteModel, ValidateModel, Fetch<[PhaseRow]>, Fetch<WorkflowRow?>) = withDependencies {
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
                let validate = ValidateModel(
                    workflowID: data.id,
                    database: database,
                    worktree: worktree,
                    workflowDirectory: data.directory,
                    mcpServerCommand: Self.mcpServerCommand
                )
                let phases = Fetch(
                    wrappedValue: [],
                    CompletedPhasesRequest(workflowID: data.id),
                    animation: .default
                )
                let row = Fetch(
                    wrappedValue: nil,
                    WorkflowRowRequest(workflowID: data.id),
                    animation: .default
                )
                return (model, prd, allocate, execute, validate, phases, row)
            }
            designModel = model
            prdModel = prd
            allocateModel = allocate
            executeModel = execute
            validateModel = validate
            _completedPhases = phases
            _workflowRow = row
        } else {
            designModel = nil
            prdModel = nil
            allocateModel = nil
            executeModel = nil
            validateModel = nil
            _completedPhases = Fetch(wrappedValue: [])
            _workflowRow = Fetch(wrappedValue: nil)
        }
    }

    /// Ends any in-flight Execute run and Validate reviews when the window closes. Both cancels are
    /// `nonisolated` and no-ops when idle, so they're safe from the deinitializer.
    deinit {
        executeModel?.cancelRun()
        validateModel?.cancelAll()
    }

    /// The first Phase is always unlocked; every other unlocks once the Phase it consumes has completed.
    public func isUnlocked(_ phase: Phase) -> Bool {
        guard let predecessor = phase.predecessor else { return true }
        return completedPhases.contains { $0.kind == predecessor.rawValue }
    }

    /// The window/sidebar title: the repo name prefix plus the user-editable title.
    var title: String {
        workflowWindowDisplayTitle(repoPath: repoPath, title: rawTitle)
    }

    /// The user-editable title alone (without the repo prefix), as stored. Empty means unnamed.
    var rawTitle: String {
        workflowRow?.title ?? ""
    }

    func subtitle(phase: Phase?) -> String {
        workflowWindowDisplaySubtitle(repoPath: repoPath, phase: phase)
    }

    /// Persists a new user-editable title, bumping `updatedAt`. Invoked from the settings sheet's Done.
    public func updateTitle(_ newTitle: String) {
        @Dependency(\.date.now) var now
        guard let database else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflowID = id
        try? database.write { db in
            try WorkflowRow
                .where { $0.id.eq(workflowID) }
                .update {
                    $0.title = trimmed
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// The app binary re-executed — it branches into the stdio server at `@main` before AppKit boots,
    /// so no separate helper binary is embedded (ADR 0006).
    private static var mcpServerCommand: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }
}

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

struct WorkflowRowRequest: FetchKeyRequest {
    let workflowID: UUID

    func fetch(_ db: Database) throws -> WorkflowRow? {
        try WorkflowRow
            .where { $0.id.eq(workflowID) }
            .where { !$0.isDeleted }
            .fetchOne(db)
    }
}
