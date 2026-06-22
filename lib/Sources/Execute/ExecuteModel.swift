import Agent
import Dependencies
import Foundation
import IssueGraph
import Material
import Observation
import SQLiteData
import Store

/// Drives the Execute Phase: a read-only dependency DAG of the Workflow's committed Issues plus a
/// sequential executor. It owns no chat — it observes the Issue rows and runs each behind the scenes.
@MainActor
@Observable
public final class ExecuteModel {
    @ObservationIgnored
    @Fetch var issues: [IssueRow] = []

    public var selectedID: Int?

    /// The DAG recolors off the observed Issue rows, not this flag.
    public private(set) var isRunning = false

    /// Boxed so the run can be cancelled off the MainActor — both Stop and the window's teardown
    /// (`cancelRun`) route here.
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

    @ObservationIgnored
    private let skill: SkillResource

    @ObservationIgnored
    private let worktree: URL

    /// Evaluated once when the window opens; `true` means the worktree was pruned or deleted outside
    /// Hercules, which blocks the Phase rather than falling back to the user's raw checkout.
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

    public var worktreeMessage: String? {
        guard worktreeMissing else { return nil }
        return "This Workflow's git worktree is missing — expected at \(worktree.path). It may have been pruned or deleted outside Hercules. Recreating it isn't supported yet, so the Execute Phase can't run until it's restored."
    }

    public var isEmpty: Bool { issues.isEmpty }

    public var nodes: [DAGNode] { dagNodes(from: issues) }

    /// A dependency cycle or reference to an unknown Issue number; `nil` when the graph is a valid DAG.
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

    /// Empty when validation fails, so `layeredLayout` is never run on a cycle (which it isn't defined for).
    public var layoutNodes: [IssueGraph.LayoutNode] {
        guard validationError == nil else { return [] }
        return IssueGraph.layeredLayout(nodes)
    }

    public var nodesByNumber: [Int: DAGNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })
    }

    public var selectedIssue: IssueRow? {
        guard let selectedID else { return nil }
        return issues.first { $0.number == selectedID }
    }

    /// Tapping a node's own card again clears the selection.
    public func selectNode(_ number: Int) {
        selectedID = selectedID == number ? nil : number
    }

    public var canRun: Bool {
        !isRunning && validationError == nil && !isEmpty && !worktreeMissing
    }

    /// The task is retained in `runTask` so `stop()` and the window's teardown can cancel it.
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

    public func stop() {
        cancelRun()
    }

    /// `nonisolated` so the window's teardown can cancel from any isolation. Cancelling throws the Turn,
    /// which leaves the worked Issue `failed`.
    public nonisolated func cancelRun() {
        runTask.value?.cancel()
    }

    /// Runs one Issue as a behind-the-scenes write agent and writes its status directly via the Store
    /// (no MCP, no presented chat): `done` if the Turn finished, `failed` if it threw.
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

    /// Runs every ready Issue sequentially in dependency order, halting on the first failure. Reconciles
    /// stale `in_progress` Issues (left by a crash) back to `failed` first, and completes the Phase only
    /// once every Issue is `done` — a blocked branch must not falsely unlock Validate. Re-running resumes
    /// from the first ready `new` Issue; there is no auto-retry.
    public func run() async {
        try? database.reconcileStaleInProgressIssues(workflowID: workflowID, now: now)

        while let next = readyIssue() {
            await runIssue(next)
            if currentStatus(of: next.number) == IssueRunStatus.failed.rawValue { return }
        }

        let remaining = (try? currentIssues()) ?? []
        if !remaining.isEmpty, remaining.allSatisfy({ $0.status == IssueRunStatus.done.rawValue }) {
            try? database.completePhase(workflowID: workflowID, kind: "execute", id: uuid(), now: now)
        }
    }

    /// Lowest-numbered `new` Issue whose every dependency is `done`. Read fresh from the database so it
    /// reflects the status `runIssue` just wrote, not the lazily-updated `issues` observation.
    private func readyIssue() -> IssueRow? {
        let issues = (try? currentIssues()) ?? []
        let done = Set(issues.filter { $0.status == IssueRunStatus.done.rawValue }.map(\.number))
        return issues
            .filter { $0.status == "new" }
            .filter { $0.dependencies.allSatisfy(done.contains) }
            .min { $0.number < $1.number }
    }

    /// Read straight from the database, not the lazily-updated `issues` projection, so the loop sees each
    /// status write the instant it lands.
    private func currentIssues() throws -> [IssueRow] {
        try database.read { db in try WorkflowIssuesRequest(workflowID: workflowID).fetch(db) }
    }

    private func currentStatus(of number: Int) -> String? {
        ((try? currentIssues()) ?? []).first { $0.number == number }?.status
    }
}
