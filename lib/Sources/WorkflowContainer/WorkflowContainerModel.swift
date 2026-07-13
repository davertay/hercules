import Allocate
import Design
import Dependencies
import Execute
import Foundation
import Observation
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

    /// The four Phase models, built once the Store opens. `nil` if the Store could not be opened.
    @ObservationIgnored
    public let designModel: DesignModel?

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

    /// Set when ``destroy()`` removed the Workflow but a git cleanup step failed — the view surfaces it as
    /// a brief non-blocking notice before closing the window.
    public var cleanupNotice: String?

    /// The launcher's open-window registry, if this window was opened from the app. The model registers its
    /// id on construction and unregisters on teardown so the launcher can tell which Workflows are open.
    @ObservationIgnored
    private let registry: OpenWorkflowRegistry?

    public init(data: WorkflowWindowData, registry: OpenWorkflowRegistry? = nil) {
        id = data.id
        directory = data.directory
        repoPath = data.repoPath
        self.registry = registry
        registry?.registerOnOpen(data.id)

        // The worktree path is a pure convention derived from the directory, so a state-restored reopen
        // recomputes it and reads the already-existing on-disk worktree without re-creating it.
        let worktree = workflowWorktree(in: data.directory)

        let database = try? openWorkflowDatabase(at: data.directory)
        self.database = database
        if let database {
            // Scope `defaultDatabase` so the models' fetches observe this Workflow's Store. Every Workflow
            // runs the same four Phases (Design → Allocate → Execute → Validate), so all four models are
            // built unconditionally.
            let (design, allocate, execute, validate, phases, row): (DesignModel, AllocateModel, ExecuteModel, ValidateModel, Fetch<[PhaseRow]>, Fetch<WorkflowRow?>) = withDependencies {
                $0.defaultDatabase = database
            } operation: {
                let design = DesignModel(
                    worktree: worktree,
                    workflowID: data.id,
                    workflowDirectory: data.directory,
                    mcpServerCommand: Self.mcpServerCommand,
                    database: database
                )
                let allocate = AllocateModel(
                    worktree: worktree,
                    workflowID: data.id,
                    workflowDirectory: data.directory,
                    mcpServerCommand: Self.mcpServerCommand,
                    database: database
                )
                let execute = ExecuteModel(
                    workflowID: data.id,
                    database: database,
                    worktree: worktree,
                    workflowDirectory: data.directory
                )
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
                return (design, allocate, execute, validate, phases, row)
            }
            designModel = design
            allocateModel = allocate
            executeModel = execute
            validateModel = validate
            _completedPhases = phases
            _workflowRow = row
        } else {
            designModel = nil
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
        registry?.unregisterOnTeardown(id)
    }

    /// `true` while any one of the four Phases' agents is running — the chat Phases (Design/Allocate)
    /// mid-Turn, the Execute run loop in flight, or any Validate Persona reviewing. The single aggregate
    /// the toolbar consumes: ``isIdle`` gates Destroy, and this will gate Stop in a later slice.
    public var isRunning: Bool {
        designModel?.isBusy == true
            || allocateModel?.isBusy == true
            || executeModel?.isRunning == true
            || validateModel?.isAnyRunning == true
    }

    /// The whole Workflow is quiescent — none of the four Phases' agents are running.
    public var isIdle: Bool { !isRunning }

    /// Stops every running agent across all four Phases in one call — the Workflow-level "stop
    /// everything". The two chat Phases cancel their in-flight Turn, Execute cancels its run loop (which
    /// leaves the in-flight Issue `failed`), and Validate cancels every in-flight Persona. Each cancel is
    /// a no-op when its Phase is idle, so this is safe to call at any time.
    public func stopAll() {
        designModel?.cancel()
        allocateModel?.cancel()
        executeModel?.cancelRun()
        validateModel?.cancelAll()
    }

    /// Tears down the Workflow via ``deleteWorkflow(data:root:)``. Folder removal is the operation of
    /// record, so the Workflow always disappears; the caller should close the window afterwards. Returns
    /// `true` on a fully clean teardown. On a git-step failure it sets ``cleanupNotice`` and returns
    /// `false` so the caller can surface the notice before closing — the removal is still treated as done.
    @discardableResult
    public func destroy() -> Bool {
        let root = directory.deletingLastPathComponent()
        let data = WorkflowWindowData(id: id, directory: directory, repoPath: repoPath)
        let result = deleteWorkflow(data: data, root: root)
        guard result.didGitCleanupSucceed else {
            cleanupNotice = "Workflow removed, but its git branch or worktree may need manual cleanup."
            return false
        }
        return true
    }

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
