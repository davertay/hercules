import Agent
import DAGGraphUI
import Dependencies
import Foundation
import IssueGraph
import Material
import Observation
import SQLiteData
import Store
import Worktree

/// Drives the Execute Phase: a read-only dependency DAG of the Workflow's committed Issues plus a
/// sequential executor. It owns no chat — it observes the Issue rows and runs each behind the scenes.
@MainActor
@Observable
public final class ExecuteModel {
    @ObservationIgnored
    @Fetch var issues: [IssueRow] = []

    /// Per-Issue failure reasons recovered from the transcript (the latest errored `turn.finalAnswer`),
    /// observed so a relaunched window shows a failed Issue's reason even though the live in-process
    /// `failureReason` write didn't outlast the previous process.
    @ObservationIgnored
    @Fetch var transcriptFailureReasons: [Int: String] = [:]

    @ObservationIgnored
    @Fetch var activityCounts: [Int: ActivityCounts] = [:]

    public private(set) var clock: Date = .distantPast

    @ObservationIgnored
    let tickTask = LockIsolated<Task<Void, Never>?>(nil)

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
    @Dependency(\.worktreeClient) private var worktreeClient

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
        _transcriptFailureReasons = Fetch(
            wrappedValue: [:],
            IssueFailureReasonsRequest(workflowID: workflowID),
            animation: .default
        )
        _activityCounts = Fetch(
            wrappedValue: [:],
            IssueActivityRequest(workflowID: workflowID),
            animation: .default
        )
    }

    public var worktreeMessage: String? {
        guard worktreeMissing else { return nil }
        return "This Workflow's git worktree is missing — expected at \(worktree.path). It may have been pruned or deleted outside Hercules. Recreating it isn't supported yet, so the Execute Phase can't run until it's restored."
    }

    public var isEmpty: Bool { issues.isEmpty }

    /// Re-reads the Issue rows from disk. The Allocate Phase writes Issues out-of-process through the
    /// create-issue MCP server (ADR 0006), and cross-process commits don't fire this `@Fetch`'s
    /// observation — so the view forces a reload when it appears rather than trusting the snapshot taken
    /// when the window opened.
    public func refresh() async {
        try? await $issues.load()
        try? await $transcriptFailureReasons.load()
        try? await $activityCounts.load()
    }

    /// The render-ready activity for one node: live counts always, elapsed live-ticking while the node is
    /// `.inProgress` and frozen at the run's duration once done, cost shown only once finalized. Returns
    /// `nil` for a node that has never run (no Session yet) so its card shows no footer.
    public func activity(for node: DAGNode) -> NodeActivity? {
        guard let counts = activityCounts[node.number] else { return nil }
        let running = node.status == .inProgress
        let elapsed: Duration?
        if running, let startedAt = counts.startedAt {
            elapsed = .seconds(max(0, clock.timeIntervalSince(startedAt)))
        } else if let durationMs = counts.durationMs {
            elapsed = .milliseconds(durationMs)
        } else {
            elapsed = nil
        }
        // A genuine `$0.00` reads as broken, so a finalized zero (e.g. fully cached) shows nothing.
        let cost = (!running && (counts.costUSD ?? 0) > 0) ? counts.costUSD : nil
        return NodeActivity(
            steps: counts.steps,
            tools: counts.tools,
            elapsed: elapsed,
            cost: cost,
            isRunning: running
        )
    }

    /// The reason to show for a `failed` Issue: the Harness's own words from the transcript when present,
    /// else the reason stored on the Issue row (which covers failures thrown before any Turn existed,
    /// e.g. a missing harness binary).
    public func failureReason(for issue: IssueRow) -> String? {
        transcriptFailureReasons[issue.number] ?? issue.failureReason
    }

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

    /// The lowest-numbered `failed` Issue — the one that halted the last run. Drives the halt banner.
    public var haltingFailure: IssueRow? {
        issues
            .filter { $0.status == IssueRunStatus.failed.rawValue }
            .min { $0.number < $1.number }
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
        startClock()
        let task = Task { [self] in
            await run()
            isRunning = false
            runTask.setValue(nil)
            stopClock()
        }
        runTask.setValue(task)
    }

    /// Advances `clock` once a second while a run is underway, so in-progress cards' elapsed counts up.
    /// One timer for the whole run, cancelled when it ends — an idle window runs no timer at all.
    private func startClock() {
        clock = now
        let task = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                clock = now
            }
        }
        tickTask.setValue(task)
    }

    private func stopClock() {
        tickTask.value?.cancel()
        tickTask.setValue(nil)
    }

    public func stop() {
        cancelRun()
    }

    /// `nonisolated` so the window's teardown can cancel from any isolation. Cancelling throws the Turn,
    /// which leaves the worked Issue `failed`.
    public nonisolated func cancelRun() {
        runTask.value?.cancel()
        tickTask.value?.cancel()
    }

    /// Runs one Issue as a behind-the-scenes write agent and writes its status directly via the Store
    /// (no MCP, no presented chat). `done` is contingent on the agent committing: HEAD must advance over
    /// the run (issue #127). A no-op, a blocked agent, or one that ended on a question all leave HEAD
    /// where it was and are recorded `failed`, never `done`. The catch path covers a throw before any
    /// Turn exists (e.g. a missing harness binary).
    public func runIssue(_ issue: IssueRow) async {
        let issueNumber = issue.number
        try? database.setIssueStatus(workflowID: workflowID, number: issueNumber, to: .inProgress, now: now)

        // HEAD before the run — the baseline a commit must move off. If we can't read it we can't verify
        // the work, so fail closed rather than fall through to `done`.
        let before: String
        do {
            before = try worktreeClient.headSHA(worktree)
        } catch {
            failIssue(issueNumber, reason: verifyFailedReason(error))
            return
        }

        let session: Session
        do {
            session = try await agentClient.start(
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
        } catch {
            // The agent can throw before any `turn` row exists (e.g. a missing harness binary), so record
            // the reason on the Issue itself rather than relying on the transcript.
            failIssue(issueNumber, reason: error.localizedDescription)
            return
        }

        // The Turn finished without throwing, but "finished" isn't "did the work". Only a new commit —
        // HEAD advancing — counts as `done`.
        let after: String
        do {
            after = try worktreeClient.headSHA(worktree)
        } catch {
            failIssue(issueNumber, reason: verifyFailedReason(error))
            return
        }
        if after != before {
            try? database.setIssueStatus(workflowID: workflowID, number: issueNumber, to: .done, now: now)
        } else {
            failIssue(issueNumber, reason: noCommitReason(session: session))
        }
    }

    private func failIssue(_ number: Int, reason: String) {
        try? database.setIssueStatus(
            workflowID: workflowID, number: number, to: .failed, failureReason: reason, now: now
        )
    }

    private func verifyFailedReason(_ error: any Error) -> String {
        "Couldn't verify the worktree advanced — reading HEAD failed: \(error.localizedDescription)"
    }

    /// Why an Issue produced no commit: the agent's own parting words (the last Turn's final answer) when
    /// it left any — usually the clearest signal ("I'm blocked …") — else a default keyed to whether the
    /// worktree was left dirty. `isDirty` only sharpens the wording, so a git error there falls back to
    /// the clean-tree default rather than masking the real verdict.
    private func noCommitReason(session: Session) -> String {
        // `try?` flattens the helper's `String?` to a single optional, so one bind reaches the answer.
        if let answer = try? database.latestTurnFinalAnswer(sessionID: session.id.rawValue), !answer.isEmpty {
            return answer
        }
        let dirty = (try? worktreeClient.isDirty(worktree)) ?? false
        return dirty
            ? "The agent changed files but committed nothing — Execute requires each Issue's work to be committed."
            : "The agent produced no commit and made no changes."
    }

    /// Approves a HITL Proposed Issue (ADR 0007): `proposed` → `new`, so the next run picks it up in
    /// dependency order. A proposed Issue has no dependencies, so it's immediately ready. The observed
    /// rows recolour it from proposed to ready without a manual refresh.
    public func approve(_ number: Int) {
        try? database.approveIssue(workflowID: workflowID, number: number, now: now)
    }

    /// Denies a HITL Proposed Issue: soft-deletes it so it leaves the graph, clearing the selection it
    /// was occupying.
    public func deny(_ number: Int) {
        try? database.denyIssue(workflowID: workflowID, number: number, now: now)
        if selectedID == number { selectedID = nil }
    }

    /// Resets a `failed` Issue to `new` and immediately resumes the run from it. The run loop already
    /// starts at the lowest ready `new` Issue, so this both retries the failure and continues downstream.
    public func retry(_ number: Int) {
        guard !isRunning else { return }
        try? database.resetIssue(workflowID: workflowID, number: number, now: now)
        start()
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
