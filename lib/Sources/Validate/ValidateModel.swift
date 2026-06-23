import Agent
import Dependencies
import Foundation
import Material
import Observation
import SQLiteData
import Store

/// Drives the Validate Phase: the behind-the-scenes review runner. The Validate analogue of Execute's
/// per-Issue runner, but reviews are concurrent and independent — each Persona runs a fresh read-only
/// `validate`-kind Session in the worktree and captures the single Turn's final answer as its Summary.
/// It owns no chat; the view recolours off the observed `review` rows.
@MainActor
@Observable
public final class ValidateModel {
    @ObservationIgnored
    @Fetch var reviews: [ReviewRow] = []

    public var selectedPersona: ReviewPersona?

    /// One live run task per Persona, so several reviews proceed at once (vs Execute's single `runTask`).
    /// Boxed so the window's teardown (`cancelAll`) can cancel them off the MainActor.
    @ObservationIgnored
    let runTasks = LockIsolated<[ReviewPersona: Task<Void, Never>]>([:])

    @ObservationIgnored
    @Dependency(\.agentClient) private var agentClient

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    @ObservationIgnored
    private let worktree: URL

    /// Evaluated once when the window opens; `true` means the worktree was pruned or deleted outside
    /// Hercules, which blocks the Phase rather than reviewing the user's raw checkout.
    public let worktreeMissing: Bool

    public init(workflowID: UUID, database: any DatabaseWriter, worktree: URL) {
        self.workflowID = workflowID
        self.database = database
        self.worktree = worktree
        worktreeMissing = !FileManager.default.fileExists(atPath: worktree.path)

        // Window open: with no live orchestrator yet, any `running` row is stale (a crash/quit during a
        // prior run), so demote it to `failed` before observing — mirrors reconcileStaleInProgressIssues.
        @Dependency(\.date.now) var now
        try? database.reconcileStaleRunningReviews(workflowID: workflowID, now: now)

        _reviews = Fetch(
            wrappedValue: [],
            WorkflowReviewsRequest(workflowID: workflowID),
            animation: .default
        )
    }

    public var worktreeMessage: String? {
        guard worktreeMissing else { return nil }
        return "This Workflow's git worktree is missing — expected at \(worktree.path). It may have been pruned or deleted outside Hercules. Recreating it isn't supported yet, so the Validate Phase can't run until it's restored."
    }

    /// The behind-the-scenes Validate runs commit nothing and never finish a conversation — the Persona
    /// skill carries the review instructions, so the prompt only kicks the single Turn off.
    static let reviewPrompt =
        "Review the work on the current branch and report your findings as instructed."

    /// Re-reads the review rows from disk. A relaunched window observes its own writes, but the eager load
    /// mirrors Execute so the surface is current the instant it appears.
    public func refresh() async {
        try? await $reviews.load()
    }

    /// The persisted row for `persona`, or `nil` when the Persona has never run (idle).
    public func reviewRow(for persona: ReviewPersona) -> ReviewRow? {
        reviews.first { $0.kind == persona.rawValue }
    }

    /// The Persona's lifecycle status; `nil` (idle) when no row exists yet.
    public func status(for persona: ReviewPersona) -> ReviewStatus? {
        reviewRow(for: persona).flatMap { ReviewStatus(rawValue: $0.status) }
    }

    /// `true` while a run task for this Persona is live. Drives the per-card action and run-gating; the
    /// node colour comes from the observed row instead.
    public func isRunning(_ persona: ReviewPersona) -> Bool {
        runTasks.withValue { $0[persona] != nil }
    }

    /// `true` if any review is currently running — used to gate the terminal PR action.
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

    /// Tapping a node's own card again clears the selection.
    public func selectNode(_ persona: ReviewPersona) {
        selectedPersona = selectedPersona == persona ? nil : persona
    }

    /// Starts (or re-runs) a Persona. The task is retained in `runTasks` so `cancelAll` can cancel it.
    public func run(_ persona: ReviewPersona) {
        guard canRun(persona) else { return }
        let task = Task { [self] in
            await review(persona)
            runTasks.withValue { $0[persona] = nil }
        }
        runTasks.withValue { $0[persona] = task }
    }

    /// Runs one Persona's review as a read-only behind-the-scenes Session and writes its status directly
    /// via the Store (no presented chat): `reviewed` with the captured Summary if the Turn finished,
    /// `failed` with the reason if it threw (an interrupt is recorded distinctly).
    func review(_ persona: ReviewPersona) async {
        let kind = persona.rawValue
        try? database.upsertReview(workflowID: workflowID, kind: kind, to: .running, now: now)
        do {
            let resource = persona.skillResource
            let session = try await agentClient.start(
                StartRequest(
                    prompt: Self.reviewPrompt,
                    worktree: worktree,
                    mode: .readOnly,
                    database: database,
                    workflowID: workflowID,
                    kind: .validate,
                    skillFiles: [resource.fileUrl],
                    addDirs: [resource.folderUrl]
                )
            )
            try? database.setReviewSession(
                workflowID: workflowID, kind: kind, sessionID: session.id.rawValue, now: now
            )
            // The Summary is the Turn's final answer (same mechanism as Design/PRD finalization), but the
            // sink is the row's `summary` column rather than a markdown Artifact.
            let summary = try? database.latestFinalAnswer(forSession: session.id.rawValue)
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

    /// `nonisolated` so the window's teardown can cancel from any isolation. Cancelling throws each live
    /// run's Turn, which the `review` catch records as a failed "Interrupted" row.
    public nonisolated func cancelAll() {
        runTasks.withValue { tasks in
            for task in tasks.values { task.cancel() }
        }
    }
}
