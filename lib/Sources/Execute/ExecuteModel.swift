import Agent
import DAGGraphUI
import Dependencies
import Foundation
import IssueGraph
import Skills
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

    @ObservationIgnored
    @Fetch var transcriptFailureReasons: [Int: String] = [:]

    @ObservationIgnored
    @Fetch var activityCounts: [Int: ActivityCounts] = [:]

    /// The shared once-a-second ticker in-progress cards' elapsed counts up on. One timer for the whole
    /// run, stopped when it ends — an idle window runs none.
    @ObservationIgnored
    private let ticker = TickClock()

    public var clock: Date { ticker.now }

    public var selectedID: Int?

    public private(set) var isRunning = false

    /// When a run is paused waiting out a session-limit reset, the instant it will auto-resume (the
    /// parsed reset time plus a one-minute grace buffer); `nil` otherwise. Drives the resume banner and
    /// keeps the paused Issue out of `.inProgress` while the run stays `isRunning`. Cleared the moment
    /// the wait ends, whether it elapses or Stop cancels it.
    public private(set) var resumingAt: Date?

    /// The Issue number the run is currently waiting to auto-resume, held alongside `resumingAt` so the
    /// paused node can be presented as pending/next-up rather than a red failed node.
    @ObservationIgnored
    private var resumingIssueNumber: Int?

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

    /// Drives the in-loop session-limit wait (`sleep(for:)`), injected so tests advance it with a
    /// `TestClock` instead of sleeping real hours. Distinct from `clock`, the once-a-second UI tick.
    @ObservationIgnored
    @Dependency(\.continuousClock) private var continuousClock

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    @ObservationIgnored
    private let skill: SkillResource

    @ObservationIgnored
    private let worktree: URL

    /// Root for the input bundle attached to each write agent — the completed Phases' Artifacts are
    /// recorded as paths under here, in the Workflow directory rather than the worktree.
    @ObservationIgnored
    private let workflowDirectory: URL

    /// Evaluated once when the window opens; `true` means the worktree was pruned or deleted outside
    /// Hercules, which blocks the Phase rather than falling back to the user's raw checkout.
    public let worktreeMissing: Bool

    public init(context: WorkflowContext) {
        self.workflowID = context.workflowID
        self.database = context.database
        self.worktree = context.worktree
        self.workflowDirectory = context.workflowDirectory
        self.skill = loadSkill(.implementIssue)
        worktreeMissing = !FileManager.default.fileExists(atPath: context.worktree.path)
        _issues = Fetch(
            wrappedValue: [],
            WorkflowIssuesRequest(workflowID: context.workflowID),
            animation: .default
        )
        _transcriptFailureReasons = Fetch(
            wrappedValue: [:],
            IssueFailureReasonsRequest(workflowID: context.workflowID),
            animation: .default
        )
        _activityCounts = Fetch(
            wrappedValue: [:],
            IssueActivityRequest(workflowID: context.workflowID),
            animation: .default
        )
    }

    public var worktreeMessage: String? {
        guard worktreeMissing else { return nil }
        return missingWorktreeMessage(phase: "Execute", worktree: worktree)
    }

    public var isEmpty: Bool { issues.isEmpty }

    /// Re-reads the Issue rows from disk. The Allocate Phase writes Issues out-of-process through the
    /// create-issue MCP server (ADR 0006), and cross-process commits don't fire this `@Fetch`'s
    /// observation — so the view forces a reload when it appears rather than trusting the snapshot
    /// taken when the window opened.
    public func refresh() async {
        try? await $issues.load()
        try? await $transcriptFailureReasons.load()
        try? await $activityCounts.load()
    }

    /// The render-ready activity for one node. Returns `nil` for a node that has never run (no Session
    /// yet) so its card shows no footer.
    public func activity(for node: DAGNode) -> NodeActivity? {
        guard let counts = activityCounts[node.number] else { return nil }
        return NodeActivity(counts: counts, running: node.status == .inProgress, clock: clock)
    }

    /// The Harness's own words on the failure when it left any, else the reason the run recorded — with
    /// one exception: a rate limit we couldn't time, where the Harness's words are precisely the words we
    /// couldn't read, and our account of why the run stopped instead of waiting is the more useful one.
    /// That account is recognised by the Issue's own recorded reason, the durable record of the halt, so
    /// it reads the same after a relaunch as the transcript projection does — and a fresh attempt clears
    /// it with every other failure reason, since a new run supersedes the verdict.
    public func failureReason(for issue: IssueRow) -> String? {
        if issue.failureReason == Self.unreadableResetReason { return issue.failureReason }
        return transcriptFailureReasons[issue.number] ?? issue.failureReason
    }

    /// The Issue the run is waiting to auto-resume after a session-limit halt; `nil` when no wait is in
    /// flight. The single source of truth for the paused Issue, so the resume banner and the paused-node
    /// recolouring name the same one. Deliberately *not* `haltingFailure` (the lowest-numbered `failed`
    /// Issue), which can name a different, pre-existing failure.
    public var resumingIssue: IssueRow? {
        guard resumingAt != nil, let number = resumingIssueNumber else { return nil }
        return issues.first { $0.number == number }
    }

    public var nodes: [DAGNode] {
        let nodes = dagNodes(from: issues)
        // While waiting out a session-limit reset the Issue is still `failed` in the store (so Stop
        // leaves it a normal failure with its Retry) — present it as the pending/next-up node, never a
        // red failed one, and never `.inProgress`, which would clock the multi-hour wait into its
        // NodeActivity elapsed.
        guard let paused = resumingIssue else { return nodes }
        return nodes.map { node in
            node.number == paused.number
                ? DAGNode(number: node.number, title: node.title, status: .ready, dependencies: node.dependencies)
                : node
        }
    }

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

    /// The per-Workflow Store the runs are projected into, exposed read-only so the inspector can drive a
    /// diagnostic `TranscriptView` off it.
    public var transcriptDatabase: any DatabaseReader { database }

    public func transcriptSession(for issue: IssueRow) -> SessionRow? {
        try? database.session(forIssue: issue.number, workflowID: workflowID)
    }

    public func lastTurnAnswer(for issue: IssueRow) -> String? {
        guard
            issue.statusValue == .done,
            let session = transcriptSession(for: issue),
            let answer = try? database.latestTurnFinalAnswer(sessionID: session.id),
            !answer.isEmpty
        else { return nil }
        return answer
    }

    public var haltingFailure: IssueRow? {
        issues
            .filter { $0.statusValue == .failed }
            .min { $0.number < $1.number }
    }

    public func selectNode(_ number: Int) {
        selectedID = selectedID == number ? nil : number
    }

    public var canRun: Bool {
        !isRunning && validationError == nil && !isEmpty && !worktreeMissing
    }

    public func start() {
        guard canRun else { return }
        isRunning = true
        ticker.start()
        let task = Task { [self] in
            await run()
            isRunning = false
            runTask.setValue(nil)
            ticker.stop()
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
        ticker.stop()
    }

    /// Runs one Issue as a behind-the-scenes write agent and writes its status directly via the Store
    /// (no MCP, no presented chat). `done` is contingent on the agent committing: HEAD must advance over
    /// the run. A no-op, a blocked agent, or one that ended on a question all leave HEAD where it was
    /// and are recorded `failed`, never `done`.
    ///
    /// Returns whether the run failed on a rate limit the Harness reported for itself — the run loop's
    /// only evidence for a failure worth waiting out. `false` for every other outcome, including a
    /// failure whose Harness reported no reason at all.
    @discardableResult
    public func runIssue(_ issue: IssueRow) async -> Bool {
        let issueNumber = issue.number
        try? database.setIssueStatus(workflowID: workflowID, number: issueNumber, to: .inProgress, now: now)

        // HEAD before the run — the baseline a commit must move off. If we can't read it we can't verify
        // the work, so fail closed rather than fall through to `done`.
        let before: String
        do {
            before = try worktreeClient.headSHA(worktree)
        } catch {
            failIssue(issueNumber, reason: verifyFailedReason(error))
            return false
        }

        let session: Session
        do {
            session = try await agentClient.start(
                StartRequest(
                    prompt: prompt(for: issue),
                    worktree: worktree,
                    mode: .write,
                    inputs: inputArtifacts(),
                    database: database,
                    workflowID: workflowID,
                    kind: .execute,
                    issueNumber: issueNumber,
                    skillFiles: [skill.fileUrl],
                    addDirs: [skill.folderUrl],
                    trustsRepositorySettings: database.trustsRepositorySettings(workflowID: workflowID)
                )
            )
        } catch {
            // The agent can throw before any `turn` row exists (e.g. a missing harness binary), so record
            // the reason on the Issue itself rather than relying on the transcript.
            failIssue(issueNumber, reason: error.localizedDescription)
            return (error as? AgentError)?.isReportedRateLimit ?? false
        }

        let after: String
        do {
            after = try worktreeClient.headSHA(worktree)
        } catch {
            failIssue(issueNumber, reason: verifyFailedReason(error))
            return false
        }
        if after != before {
            try? database.setIssueStatus(workflowID: workflowID, number: issueNumber, to: .done, now: now)
        } else {
            failIssue(issueNumber, reason: noCommitReason(session: session))
        }
        return false
    }

    /// The prompt for one run of an Issue. The **first** run sends the Issue body unchanged; any
    /// **re-run** — detected purely by an existing execute Session for the Issue, whether from an
    /// auto-resume or a manual Retry — appends a note telling the fresh session to inspect the worktree
    /// and continue the possibly-partial work already on disk rather than starting over.
    private func prompt(for issue: IssueRow) -> String {
        let priorSession = (try? database.session(forIssue: issue.number, workflowID: workflowID)) ?? nil
        guard priorSession != nil else { return issue.body }
        return "\(issue.body)\n\n\(Self.rerunInterruptionNote)"
    }

    private static let rerunInterruptionNote = """
        A previous attempt at this issue was interrupted before it finished. It may have left partial, \
        uncommitted work in the worktree. Inspect the working tree first; continue from where it left off \
        rather than starting over, and commit when the work is complete.
        """

    private func failIssue(_ number: Int, reason: String) {
        try? database.setIssueStatus(
            workflowID: workflowID, number: number, to: .failed, failureReason: reason, now: now
        )
    }

    private func verifyFailedReason(_ error: any Error) -> String {
        "Couldn't verify the worktree advanced — reading HEAD failed: \(error.localizedDescription)"
    }

    /// What a rate limit reports when the Harness's message carried no reset time we could read. There is
    /// nothing to sleep until, so the run says so and stops, rather than reporting a generic failure or
    /// guessing at when a limit we can't see the end of will clear. Recorded on the Issue, where it is
    /// also what `failureReason(for:)` recognises the halt by — so it is written in exactly one place.
    private static let unreadableResetReason = """
        Hit a rate limit, but couldn't read a reset time out of the Harness's message — halted here. \
        Retry once the limit clears.
        """

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

    /// Runs every ready Issue sequentially in dependency order. Reconciles stale `in_progress` Issues
    /// (left by a crash) back to `failed` first, and completes the Phase only once every Issue is `done`
    /// — a blocked branch must not falsely unlock Validate. A rate limit the Harness reported for itself
    /// is the one failure that doesn't end the run: it waits out the reset, then re-runs the Issue and
    /// carries on downstream. Every other failure — and a wait cancelled by Stop — halts the run with the
    /// Issue left `failed` for a manual Retry.
    public func run() async {
        try? database.reconcileStaleInProgressIssues(workflowID: workflowID, now: now)

        while let next = readyIssue() {
            let reportedRateLimit = await runIssue(next)
            if currentStatus(of: next.number) == .failed {
                guard await awaitSessionLimitReset(for: next.number, reportedRateLimit: reportedRateLimit)
                else { return }
                try? database.resetIssue(workflowID: workflowID, number: next.number, now: now)
            }
        }

        let remaining = (try? currentIssues()) ?? []
        if !remaining.isEmpty, remaining.allSatisfy({ $0.statusValue == .done }) {
            try? database.completePhase(workflowID: workflowID, kind: .execute, id: uuid(), now: now)
        }
    }

    /// Sleeps out a rate limit the Harness reported for itself, until its reset plus a one-minute grace
    /// buffer, then returns `true` so the caller re-runs the Issue.
    ///
    /// The gate is `reportedRateLimit` — what the Harness said about its own failure — and never the
    /// wording of the failure: a crash whose parting words happen to mention a session limit is a crash,
    /// and halts rather than parking the run for hours. The message is still where the *timing* comes
    /// from, because the reset time appears nowhere else; a limit whose time it doesn't yield is recorded
    /// as exactly that and halts for a manual Retry, rather than being given a backoff we'd have to
    /// invent. Returns `false` for every halt, and when Stop cancels the sleep. The run stays `isRunning`
    /// throughout.
    private func awaitSessionLimitReset(for number: Int, reportedRateLimit: Bool) async -> Bool {
        guard reportedRateLimit else { return false }

        let message = (try? database.latestExecuteErrorMessage(forIssue: number, workflowID: workflowID)) ?? nil
        guard let resetAt = message.flatMap({ SessionLimitReset.parse($0, now: now) }) else {
            failIssue(number, reason: Self.unreadableResetReason)
            return false
        }

        let resumeAt = resetAt.addingTimeInterval(60)
        resumingAt = resumeAt
        resumingIssueNumber = number
        defer {
            resumingAt = nil
            resumingIssueNumber = nil
        }

        do {
            try await continuousClock.sleep(for: .seconds(resumeAt.timeIntervalSince(now)))
        } catch {
            return false
        }
        return true
    }

    /// Lowest-numbered `new` Issue whose every dependency is `done`. Read fresh from the database so it
    /// reflects the status `runIssue` just wrote, not the lazily-updated `issues` observation.
    private func readyIssue() -> IssueRow? {
        let issues = (try? currentIssues()) ?? []
        let done = Set(issues.filter { $0.statusValue == .done }.map(\.number))
        return issues
            .filter { $0.statusValue == .new }
            .filter { $0.dependencies.allSatisfy(done.contains) }
            .min { $0.number < $1.number }
    }

    /// The completed PRD and Design summary Artifacts as one input bundle — PRD first, then summary — so
    /// the `implement-issue` Skill's "read the design and PRD" step is satisfiable. Best-effort:
    /// attaches whichever Artifacts exist and skips any that are absent, so a missing one never fails,
    /// blocks, or warns. Returns `nil` when none exist.
    private func inputArtifacts() -> InputBundle? {
        let paths = [PhaseKind.prd, .design].compactMap { kind in
            try? database.completedArtifactPath(workflowID: workflowID, kind: kind)
        }
        guard !paths.isEmpty else { return nil }
        return InputBundle(
            root: workflowDirectory,
            relativePaths: paths.map { workflowRelativePath(of: $0, under: workflowDirectory) }
        )
    }

    /// Read straight from the database, not the lazily-updated `issues` projection, so the loop sees each
    /// status write the instant it lands.
    private func currentIssues() throws -> [IssueRow] {
        try database.read { db in try WorkflowIssuesRequest(workflowID: workflowID).fetch(db) }
    }

    private func currentStatus(of number: Int) -> IssueRow.Status? {
        ((try? currentIssues()) ?? []).first { $0.number == number }?.statusValue
    }
}

#if DEBUG
extension ExecuteModel {
    /// Preview/debug only: drops the model into the paused session-limit presentation without a live
    /// run, so a screenshot can verify the resume banner and the next-up (not failed) node treatment.
    /// Sets the same published `resumingAt` and paused-Issue state the run loop holds while it waits.
    public func enterResumingStateForPreview(issueNumber: Int, resumingAt: Date) {
        self.resumingAt = resumingAt
        self.resumingIssueNumber = issueNumber
    }
}
#endif
