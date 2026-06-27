import Agent
import DAGGraphUI
import Dependencies
import Foundation
import Material
import Observation
import SQLiteData
import Store
import Worktree

/// Drives the Validate Phase: the behind-the-scenes review runner. The Validate analogue of Execute's
/// per-Issue runner, but reviews are concurrent and independent — each Persona runs a fresh read-only
/// `validate`-kind Session in the worktree and captures the single Turn's final answer as its Summary.
/// It owns no chat; the view recolours off the observed `review` rows.
@MainActor
@Observable
public final class ValidateModel {
    @ObservationIgnored
    @Fetch var reviews: [ReviewRow] = []

    @ObservationIgnored
    @Fetch var issues: [IssueRow] = []

    @ObservationIgnored
    @Fetch var reviewActivity: [String: ActivityCounts] = [:]

    public private(set) var clock: Date = .distantPast

    @ObservationIgnored
    let tickTask = LockIsolated<Task<Void, Never>?>(nil)

    public var selectedPersona: ReviewPersona?

    public var pullRequestConfirmation: String?

    public var pullRequestError: String?

    public var isOpeningPullRequest = false

    @ObservationIgnored
    let runTasks = LockIsolated<[ReviewPersona: Task<Void, Never>]>([:])

    @ObservationIgnored
    @Dependency(\.agentClient) private var agentClient

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    @Dependency(\.worktreeClient) private var worktreeClient

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    @ObservationIgnored
    private let worktree: URL

    @ObservationIgnored
    private let workflowDirectory: URL

    @ObservationIgnored
    private let mcpServerCommand: String

    public let worktreeMissing: Bool

    @ObservationIgnored
    private var didReconcile = false

    public init(
        workflowID: UUID,
        database: any DatabaseWriter,
        worktree: URL,
        workflowDirectory: URL,
        mcpServerCommand: String
    ) {
        self.workflowID = workflowID
        self.database = database
        self.worktree = worktree
        self.workflowDirectory = workflowDirectory
        self.mcpServerCommand = mcpServerCommand
        worktreeMissing = !FileManager.default.fileExists(atPath: worktree.path)
        _reviews = Fetch(
            wrappedValue: [],
            WorkflowReviewsRequest(workflowID: workflowID),
            animation: .default
        )
        _issues = Fetch(
            wrappedValue: [],
            WorkflowIssuesRequest(workflowID: workflowID),
            animation: .default
        )
        _reviewActivity = Fetch(
            wrappedValue: [:],
            ReviewActivityRequest(workflowID: workflowID),
            animation: .default
        )
    }

    public var worktreeMessage: String? {
        guard worktreeMissing else { return nil }
        return "This Workflow's git worktree is missing — expected at \(worktree.path). It may have been pruned or deleted outside Hercules. Recreating it isn't supported yet, so the Validate Phase can't run until it's restored."
    }

    static let reviewPrompt =
        "Review the work on the current branch and report your findings as instructed."

    public func refresh() async {
        if !didReconcile {
            didReconcile = true
            try? database.reconcileStaleRunningReviews(workflowID: workflowID, now: now)
        }
        try? await $reviews.load()
        try? await $issues.load()
        try? await $reviewActivity.load()
    }

    public func activity(for persona: ReviewPersona) -> NodeActivity? {
        guard let counts = reviewActivity[persona.rawValue] else { return nil }
        let running = isRunning(persona) || status(for: persona) == .running
        let elapsed: Duration?
        if running, let startedAt = counts.startedAt {
            elapsed = .seconds(max(0, clock.timeIntervalSince(startedAt)))
        } else if let durationMs = counts.durationMs {
            elapsed = .milliseconds(durationMs)
        } else {
            elapsed = nil
        }
        let cost = (!running && (counts.costUSD ?? 0) > 0) ? counts.costUSD : nil
        return NodeActivity(
            steps: counts.steps,
            tools: counts.tools,
            elapsed: elapsed,
            cost: cost,
            isRunning: running
        )
    }

    public func reviewRow(for persona: ReviewPersona) -> ReviewRow? {
        reviews.first { $0.kind == persona.rawValue }
    }

    public func status(for persona: ReviewPersona) -> ReviewStatus? {
        reviewRow(for: persona).flatMap { ReviewStatus(rawValue: $0.status) }
    }

    public func isRunning(_ persona: ReviewPersona) -> Bool {
        runTasks.withValue { $0[persona] != nil }
    }

    public var isAnyRunning: Bool {
        runTasks.withValue { !$0.isEmpty }
    }

    public func canRun(_ persona: ReviewPersona) -> Bool {
        !worktreeMissing && !isRunning(persona)
    }

    public var selectedReview: ReviewRow? {
        guard let selectedPersona else { return nil }
        return reviewRow(for: selectedPersona)
    }

    public func selectNode(_ persona: ReviewPersona) {
        selectedPersona = selectedPersona == persona ? nil : persona
    }

    public func run(_ persona: ReviewPersona) {
        guard canRun(persona) else { return }
        startClockIfNeeded()
        let task = Task { [self] in
            await review(persona)
            runTasks.withValue { $0[persona] = nil }
            stopClockIfIdle()
        }
        runTasks.withValue { $0[persona] = task }
    }

    private func startClockIfNeeded() {
        clock = now
        guard tickTask.value == nil else { return }
        let task = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                clock = now
            }
        }
        tickTask.setValue(task)
    }

    private func stopClockIfIdle() {
        guard !isAnyRunning else { return }
        tickTask.value?.cancel()
        tickTask.setValue(nil)
    }

    func review(_ persona: ReviewPersona) async {
        let kind = persona.rawValue
        // Forward-link the Session before the run starts (not after), so `ReviewActivityRequest` can map
        // the streaming Turn back to this Persona and the card's activity updates live.
        let sessionID = uuid()
        try? database.upsertReview(workflowID: workflowID, kind: kind, to: .running, now: now)
        try? database.setReviewSession(workflowID: workflowID, kind: kind, sessionID: sessionID, now: now)
        do {
            let resource = persona.skillResource
            _ = try await agentClient.start(
                StartRequest(
                    prompt: Self.reviewPrompt,
                    worktree: worktree,
                    mode: .readOnly,
                    database: database,
                    workflowID: workflowID,
                    kind: .validate,
                    sessionID: sessionID,
                    skillFiles: [resource.fileUrl],
                    addDirs: [resource.folderUrl],
                    mcpServers: [proposeServer()]
                )
            )
            // The Summary is the Turn's final answer (same mechanism as Design/PRD finalization), but the
            // sink is the row's `summary` column rather than a markdown Artifact.
            let summary = try? database.latestFinalAnswer(forSession: sessionID)
            try? database.upsertReview(
                workflowID: workflowID, kind: kind, to: .reviewed, summary: summary ?? nil, now: now
            )
        } catch {
            let reason = Task.isCancelled
                ? "Interrupted — the run was stopped or the app quit while this review was running."
                : error.localizedDescription
            try? database.upsertReview(
                workflowID: workflowID, kind: kind, to: .failed, failureReason: reason, now: now
            )
        }
    }

    public var canOpenPullRequest: Bool {
        !isAnyRunning && !isOpeningPullRequest && !issues.isEmpty && issues.allSatisfy { $0.status == "done" }
    }

    public func openPullRequest() async -> URL? {
        guard !isOpeningPullRequest else { return nil }
        isOpeningPullRequest = true
        defer { isOpeningPullRequest = false }
        pullRequestError = nil
        let client = worktreeClient
        let worktree = worktree
        do {
            let url = try await Task.detached {
                try client.rebaseOntoBase(worktree: worktree)
                try client.push(worktree: worktree)
                return try client.compareURL(worktree: worktree)
            }.value
            pullRequestConfirmation = "Branch pushed — finish on GitHub"
            return url
        } catch {
            pullRequestError = error.localizedDescription
            return nil
        }
    }

    public func dismissPullRequestConfirmation() {
        pullRequestConfirmation = nil
    }

    private func proposeServer() -> MCPServer {
        let databasePath = workflowDirectory.appendingPathComponent("workflow.sqlite").path
        return MCPServer(
            name: "hercules",
            command: mcpServerCommand,
            args: [
                "--mcp-issue-server",
                "--propose",
                "--db", databasePath,
                "--workflow-id", workflowID.uuidString,
            ],
            tools: ["propose_issue"]
        )
    }

    public nonisolated func cancelAll() {
        runTasks.withValue { tasks in
            for task in tasks.values { task.cancel() }
        }
        tickTask.value?.cancel()
    }
}
