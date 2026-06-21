import Agent
import Dependencies
import Foundation
import IssueGraph
import Material
import Observation
import SQLiteData
import Store

/// Drives the Execute Phase's visualization: a read-only dependency DAG of the Workflow's committed
/// Issues. Unlike the Design/PRD/Allocate models it owns no chat and spawns no Agent — it observes the
/// Issue rows and projects them into the DAG the view renders. (Scheduling and per-Issue agent runs are
/// later slices.)
///
/// The committed Issues are observed live via `WorkflowIssuesRequest`, so the graph appears the moment
/// the Allocate commit Turn writes and survives reopening the window. The `IssueRow` → `DAGNode`
/// mapping (`dagNodes(from:)`) derives each node's status from the dependency graph.
@MainActor
@Observable
public final class ExecuteModel {
    /// Live view of this Workflow's committed Issues, ordered by number. Drives the DAG; updates as the
    /// underlying rows change.
    @ObservationIgnored
    @Fetch var issues: [IssueRow] = []

    /// The Issue `number` of the node currently selected in the DAG, driving the inspector pane. `nil`
    /// when nothing is selected.
    public var selectedID: Int?

    /// Whether an Execute run is currently in flight. Drives the Run/Stop controls; the DAG itself
    /// recolors off the observed Issue rows, not off this flag.
    public private(set) var isRunning = false

    /// The in-flight orchestrator run, held in a `Sendable` box so it can be cancelled from outside the
    /// MainActor — both the user's Stop button and the Workflow window's teardown (`cancelRun`) route
    /// here. `nil` whenever no run is active.
    @ObservationIgnored
    let runTask = LockIsolated<Task<Void, Never>?>(nil)

    @ObservationIgnored
    @Dependency(\.agentClient) private var agentClient

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    /// The bundled implement-issue Skill, injected as the per-Issue write Session's system prompt (and
    /// its folder exposed via `--add-dir`) exactly as Allocate injects to-issues.
    @ObservationIgnored
    private let skill: SkillResource

    /// The Workflow's git worktree — the working tree every Phase operates in. Carried so the health
    /// check can name the expected location in its error, and the cwd each per-Issue write Session runs
    /// in.
    @ObservationIgnored
    private let worktree: URL

    /// Whether the Workflow's worktree is absent from disk, evaluated once when the window opens
    /// (creation or state-restored reopen). A `true` value means the expected `worktree/` directory was
    /// pruned or deleted outside Hercules; the Phase surfaces a blocking error rather than silently
    /// falling back to the user's raw checkout.
    public let worktreeMissing: Bool

    public init(workflowID: UUID, database: any DatabaseWriter, worktree: URL) {
        self.workflowID = workflowID
        self.database = database
        self.worktree = worktree
        self.skill = loadSkill(.implementIssue)
        worktreeMissing = !FileManager.default.fileExists(atPath: worktree.path)
        _issues = Fetch(
            wrappedValue: [],
            WorkflowIssuesRequest(workflowID: workflowID),
            animation: .default
        )
    }

    /// A human-readable description of the missing-worktree health-check failure, naming where the
    /// worktree was expected, or `nil` when it is present.
    public var worktreeMessage: String? {
        guard worktreeMissing else { return nil }
        return "This Workflow's git worktree is missing — expected at \(worktree.path). It may have been pruned or deleted outside Hercules. Recreating it isn't supported yet, so the Execute Phase can't run until it's restored."
    }

    /// True before any Issue exists — drives the empty-state placeholder. In practice Execute only
    /// unlocks once Allocate has committed at least one Issue, but the guard keeps the view honest.
    public var isEmpty: Bool { issues.isEmpty }

    /// The committed Issues projected to DAG nodes, with `ready` derived from the dependency graph.
    public var nodes: [DAGNode] { dagNodes(from: issues) }

    /// The graph-level validation failure, if any: a dependency cycle or a reference to an unknown
    /// Issue number. `nil` when the graph is a well-formed DAG. The view shows a banner and degrades to
    /// a plain Issue list when this is non-nil, since `layeredLayout`'s precondition is validated input.
    public var validationError: IssueGraph.ValidateError? {
        do {
            try IssueGraph.validate(nodes)
            return nil
        } catch let error as IssueGraph.ValidateError {
            return error
        } catch {
            return nil
        }
    }

    /// A human-readable description of `validationError`, naming the offending Issues, or `nil` when the
    /// graph is valid.
    public var validationMessage: String? {
        switch validationError {
        case .cycle(let involving):
            let list = involving.map { "#\($0)" }.joined(separator: ", ")
            return "These Issues form a dependency cycle: \(list). Resolve it in the Allocate Phase before the graph can be laid out."
        case .unknownDependency(let node, let dep):
            return "Issue #\(node) depends on #\(dep), which doesn't exist. Fix the dependency in the Allocate Phase."
        case .none:
            return nil
        }
    }

    /// Row/column coordinates for the current nodes, consumed by `DAGGraphView`. Empty when the graph
    /// fails validation, so `layeredLayout` is never run on a cycle (which it isn't defined for).
    public var layoutNodes: [IssueGraph.LayoutNode] {
        guard validationError == nil else { return [] }
        return IssueGraph.layeredLayout(nodes)
    }

    /// The current nodes keyed by Issue number, the lookup `DAGGraphView` resolves edges and cards
    /// against.
    public var nodesByNumber: [Int: DAGNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })
    }

    /// The committed Issue backing the current selection, for the inspector pane. `nil` when nothing is
    /// selected (or the selected Issue has since disappeared).
    public var selectedIssue: IssueRow? {
        guard let selectedID else { return nil }
        return issues.first { $0.number == selectedID }
    }

    /// Toggles selection of the node with `number`: selecting an unselected node, or clearing the
    /// selection when its own node is tapped again. The View dispatches the raw tap; the model owns the
    /// toggle/clear policy.
    public func selectNode(_ number: Int) {
        selectedID = selectedID == number ? nil : number
    }

    /// Whether the Run control is enabled: only when the Phase can actually start a run — no run is in
    /// flight, the dependency graph is a valid DAG, at least one Issue exists, and the worktree is on
    /// disk. The view disables Run on this; an invalid graph or in-flight run therefore can't start one.
    public var canRun: Bool {
        !isRunning && validationError == nil && !isEmpty && !worktreeMissing
    }

    /// Starts the sequential executor as the window-owned orchestrator task. Guards against a second
    /// start (and against starting when the graph is invalid), flips `isRunning` so the controls reflect
    /// the run, and drives `run()` to completion before clearing the run state. The task is retained in
    /// `runTask` so `stop()` — and the window's teardown — can cancel it; closing the window therefore
    /// ends the run rather than leaving it executing in the background.
    public func start() {
        guard canRun else { return }
        isRunning = true
        let task = Task { [self] in
            await run()
            isRunning = false
            runTask.setValue(nil)
        }
        runTask.setValue(task)
    }

    /// Stops an in-flight run on the user's command. Cancels the orchestrator task, which propagates into
    /// the running Harness's teardown (SIGTERM → SIGKILL) via the Agent's cancellation path; the
    /// cancelled Turn throws, so `runIssue` leaves the Issue it was working `failed` and the loop halts.
    public func stop() {
        cancelRun()
    }

    /// Cancels the in-flight run from any isolation — the Stop button and the Workflow window's teardown
    /// both route here, the latter so closing the window (or quitting) ends the run with no background
    /// execution. Cancelling tears down the running Harness and, via the thrown Turn, marks the worked
    /// Issue `failed`. A no-op when no run is active.
    public nonisolated func cancelRun() {
        runTask.value?.cancel()
    }

    /// Runs a single Issue end-to-end as a behind-the-scenes write agent. Marks the Issue `in_progress`,
    /// then starts a fresh `write`-mode Session in the worktree — the implement-issue Skill injected and
    /// its folder exposed, the Issue's spec body as the prompt, tagged with the `execute` kind and the
    /// Issue's `number` so its transcript stays recoverable. It awaits the Turn to completion, then
    /// writes the resulting status: `done` if the Turn finished without error, `failed` otherwise (the
    /// Agent throws when a Turn terminates abnormally).
    ///
    /// This is orchestration only: no `ChatEngine` is constructed and the conversation is not presented;
    /// the Turn is recorded through the normal transcript projection. Status is written directly via the
    /// Store helper (no MCP), since there is no status-write tool.
    public func runIssue(_ issue: IssueRow) async {
        let issueNumber = issue.number
        try? database.setIssueStatus(workflowID: workflowID, number: issueNumber, to: .inProgress, now: now)
        do {
            _ = try await agentClient.start(
                StartRequest(
                    prompt: issue.body,
                    worktree: worktree,
                    mode: .write,
                    database: database,
                    workflowID: workflowID,
                    kind: .execute,
                    issueNumber: issueNumber,
                    skillFiles: [skill.fileUrl],
                    addDirs: [skill.folderUrl]
                )
            )
            try? database.setIssueStatus(workflowID: workflowID, number: issueNumber, to: .done, now: now)
        } catch {
            try? database.setIssueStatus(workflowID: workflowID, number: issueNumber, to: .failed, now: now)
        }
    }

    /// Drives the whole Execute Phase: runs every Issue sequentially in dependency order onto the
    /// worktree's branch (parallelism is fixed at 1), halting on the first failure.
    ///
    /// At run start it reconciles any stale `in_progress` Issue — left behind by a crash or forced quit,
    /// with no live orchestrator to own it — back to `failed`. It then repeatedly selects the
    /// lowest-numbered Issue still `new` whose every dependency is `done`, runs it via `runIssue`, and
    /// inspects the status that write left behind: the first `failed` Issue halts the loop immediately —
    /// that Issue stays `failed`, the remaining Issues stay `new`, and the Phase is *not* completed. When
    /// no ready Issue remains and every Issue is `done`, the Execute Phase is marked complete, which
    /// unlocks the Validate Phase. There is no auto-retry: a re-run reconciles, skips Issues already
    /// `done`, and resumes from the first ready `new` Issue.
    public func run() async {
        try? database.reconcileStaleInProgressIssues(workflowID: workflowID, now: now)

        while let next = readyIssue() {
            await runIssue(next)
            // `runIssue` has just written `done` or `failed`; a failure halts the run, leaving the rest
            // `new` and the Phase incomplete.
            if currentStatus(of: next.number) == IssueRunStatus.failed.rawValue { return }
        }

        // The loop only exits here when nothing is ready and no failure forced an early return. Complete
        // the Phase only when every Issue actually landed `done` — a blocked branch (e.g. an unreachable
        // dependency) leaves non-`done` Issues and must not falsely unlock Validate.
        let remaining = (try? currentIssues()) ?? []
        if !remaining.isEmpty, remaining.allSatisfy({ $0.status == IssueRunStatus.done.rawValue }) {
            try? database.completePhase(workflowID: workflowID, kind: "execute", id: uuid(), now: now)
        }
    }

    /// The lowest-numbered Issue still awaiting a run (`new`) whose every dependency has reached `done` —
    /// the next Issue the loop runs, or `nil` when none is ready (all `done`, or the rest are blocked
    /// behind a dependency that isn't `done`). Read fresh from the database each call so it reflects the
    /// status `runIssue` just wrote rather than the lazily-updated `issues` observation.
    private func readyIssue() -> IssueRow? {
        let issues = (try? currentIssues()) ?? []
        let done = Set(issues.filter { $0.status == IssueRunStatus.done.rawValue }.map(\.number))
        return issues
            // `"new"` is the post-commit starting status the Allocate create-issue tool writes — the only
            // status the orchestrator treats as eligible to run (see `IssueRunStatus`).
            .filter { $0.status == "new" }
            .filter { $0.dependencies.allSatisfy(done.contains) }
            .min { $0.number < $1.number }
    }

    /// This Workflow's non-deleted Issues read straight from the database rather than the observed
    /// `issues` projection (which updates lazily), so the loop sees each status write the instant it
    /// lands.
    private func currentIssues() throws -> [IssueRow] {
        try database.read { db in try WorkflowIssuesRequest(workflowID: workflowID).fetch(db) }
    }

    /// The persisted status of the Issue numbered `number`, or `nil` if it has since disappeared.
    private func currentStatus(of number: Int) -> String? {
        ((try? currentIssues()) ?? []).first { $0.number == number }?.status
    }
}
