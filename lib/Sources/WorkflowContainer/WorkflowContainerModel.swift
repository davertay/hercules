import Allocate
import Design
import Dependencies
import Execute
import Foundation
import Observation
import PRD
import SQLiteData
import SmallJob
import Store
import Validate

@MainActor
@Observable
public final class WorkflowContainerModel {
    public let id: UUID
    public let directory: URL
    public let repoPath: String

    /// Fixed at creation and carried on ``WorkflowWindowData`` (the launcher reads it back from the
    /// `workflow` row when reopening). Drives which Phase models are built and the sidebar's Phase list.
    public let mode: WorkflowMode

    /// The per-Workflow Store, opened once for the window's lifetime so the Phases can observe it.
    @ObservationIgnored
    let database: (any DatabaseWriter)?

    /// The standard-mode chat Phases. `nil` if the Store could not be opened, or in Small Job mode, where
    /// PRD and Allocate are skipped and the Design slot is driven by ``smallJobModel`` instead.
    @ObservationIgnored
    public let designModel: DesignModel?

    @ObservationIgnored
    public let prdModel: PRDModel?

    @ObservationIgnored
    public let allocateModel: AllocateModel?

    /// The Small Job mode's first-Phase model — a grill chat that also carves Issues. Non-nil only in
    /// `small` mode, where it occupies the Design slot in place of ``designModel``.
    @ObservationIgnored
    public let smallJobModel: SmallJobModel?

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
        registry?.register(data.id)

        // The worktree path is a pure convention derived from the directory, so a state-restored reopen
        // recomputes it and reads the already-existing on-disk worktree without re-creating it.
        let worktree = workflowWorktree(in: data.directory)

        // The mode is fixed at creation and carried on the window data (read from the `workflow` row when
        // the launcher reopens an existing Workflow), so we build only the Phase models the mode needs —
        // Small Job skips PRD/Allocate and drives the Design slot via `smallJobModel`.
        let mode = data.mode
        self.mode = mode

        let database = try? openWorkflowDatabase(at: data.directory)
        self.database = database
        if let database {
            // Scope `defaultDatabase` so the models' fetches observe this Workflow's Store.
            let (design, prd, allocate, smallJob, execute, validate, phases, row): (DesignModel?, PRDModel?, AllocateModel?, SmallJobModel?, ExecuteModel, ValidateModel, Fetch<[PhaseRow]>, Fetch<WorkflowRow?>) = withDependencies {
                $0.defaultDatabase = database
            } operation: {
                let design: DesignModel?
                let prd: PRDModel?
                let allocate: AllocateModel?
                let smallJob: SmallJobModel?
                switch mode {
                case .standard:
                    design = DesignModel(
                        worktree: worktree,
                        workflowID: data.id,
                        workflowDirectory: data.directory,
                        database: database
                    )
                    prd = PRDModel(
                        worktree: worktree,
                        workflowID: data.id,
                        workflowDirectory: data.directory,
                        database: database
                    )
                    allocate = AllocateModel(
                        worktree: worktree,
                        workflowID: data.id,
                        workflowDirectory: data.directory,
                        mcpServerCommand: Self.mcpServerCommand,
                        database: database
                    )
                    smallJob = nil
                case .small:
                    design = nil
                    prd = nil
                    allocate = nil
                    smallJob = SmallJobModel(
                        worktree: worktree,
                        workflowID: data.id,
                        workflowDirectory: data.directory,
                        mcpServerCommand: Self.mcpServerCommand,
                        database: database
                    )
                }
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
                return (design, prd, allocate, smallJob, execute, validate, phases, row)
            }
            designModel = design
            prdModel = prd
            allocateModel = allocate
            smallJobModel = smallJob
            executeModel = execute
            validateModel = validate
            _completedPhases = phases
            _workflowRow = row
        } else {
            designModel = nil
            prdModel = nil
            allocateModel = nil
            smallJobModel = nil
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

    /// `true` while any one of the five Phases' agents is running — the chat Phases (Design/PRD/Allocate)
    /// mid-Turn, the Execute run loop in flight, or any Validate Persona reviewing. The single aggregate
    /// the toolbar consumes: ``isIdle`` gates Destroy, and this will gate Stop in a later slice.
    public var isRunning: Bool {
        designModel?.isBusy == true
            || prdModel?.isBusy == true
            || allocateModel?.isBusy == true
            || smallJobModel?.isBusy == true
            || executeModel?.isRunning == true
            || validateModel?.isAnyRunning == true
    }

    /// The whole Workflow is quiescent — none of the five Phases' agents are running.
    public var isIdle: Bool { !isRunning }

    /// Stops every running agent across all five Phases in one call — the Workflow-level "stop
    /// everything". The three chat Phases cancel their in-flight Turn, Execute cancels its run loop (which
    /// leaves the in-flight Issue `failed`), and Validate cancels every in-flight Persona. Each cancel is
    /// a no-op when its Phase is idle, so this is safe to call at any time.
    public func stopAll() {
        designModel?.cancel()
        prdModel?.cancel()
        allocateModel?.cancel()
        smallJobModel?.cancel()
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

    /// The first Phase is always unlocked; every other unlocks once the Phase it consumes (within this
    /// Workflow's mode topology) has completed. In Small Job, Execute unlocks on Design completing.
    public func isUnlocked(_ phase: Phase) -> Bool {
        guard let predecessor = phase.predecessor(in: mode) else { return true }
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
