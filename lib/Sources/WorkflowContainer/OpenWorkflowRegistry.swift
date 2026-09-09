import Dependencies
import Foundation
import Observation

/// Tracks which Workflows currently have an open window — open-vs-closed only, deliberately not live busy
/// state and with no DB heartbeat. The launcher consults it to disable its per-row destroy button while a
/// window is open for that Workflow; you destroy from that window's idle-gated toolbar button instead.
///
/// It is also the only place that can reach every open Workflow at once, so it is where quitting shuts
/// them down (``shutDownEverything()``).
@MainActor
@Observable
public final class OpenWorkflowRegistry {
    /// The open windows, keyed by Workflow id.
    private var openWindows: [UUID: Window] = [:]

    /// One open window: its id, and the model to bring down when the app quits.
    ///
    /// The model is held weakly because it is the window's, not this registry's. A strong reference would
    /// keep it — and every agent it owns — alive after its window had gone, and would stop the
    /// deinitializer that unregisters it from ever running.
    private struct Window {
        weak var model: WorkflowContainerModel?
    }

    public init() {}

    /// Records that a window is now open for `id`, along with the model quitting brings down. Idempotent.
    public func register(_ id: UUID, model: WorkflowContainerModel? = nil) {
        openWindows[id] = Window(model: model)
    }

    /// Schedules a ``register(_:model:)`` off the current run-loop turn. A Workflow window's model
    /// constructs during SwiftUI's view-graph update (inside `State`'s initial value), so mutating this
    /// observed state synchronously there re-enters the launcher's display cycle and AppKit throws an
    /// "Update Constraints" exception. Deferring the mutation past the active update — mirroring
    /// ``unregisterOnTeardown(_:)`` — keeps the write out of that cycle.
    ///
    /// The model is held weakly across the hop, so one dropped before the hop lands never registers at
    /// all rather than registering something already gone.
    public func registerOnOpen(_ id: UUID, model: WorkflowContainerModel) {
        Task { @MainActor [weak model] in
            guard let model else { return }
            self.register(id, model: model)
        }
    }

    /// Records that the window for `id` has closed. Idempotent.
    public func unregister(_ id: UUID) {
        openWindows[id] = nil
    }

    /// Schedules an ``unregister(_:)`` from a `nonisolated` context — a Workflow window's model unregisters
    /// here from its deinitializer, which can't synchronously touch this main-actor state.
    public nonisolated func unregisterOnTeardown(_ id: UUID) {
        Task { @MainActor in self.unregister(id) }
    }

    /// Whether a window is currently open for `id`.
    public func isOpen(_ id: UUID) -> Bool {
        openWindows[id] != nil
    }

    /// Whether any open Workflow still has an agent in flight — what quitting has to wait for, and, when
    /// it is false, what lets quitting not wait at all.
    public var hasWorkInFlight: Bool {
        openModels.contains(where: \.hasWorkInFlight)
    }

    /// How long the app gives its Workflows to come down before it terminates regardless.
    ///
    /// Wide enough for the whole of the ordinary sequence — a question declined, the grace that dismissal
    /// is given to reach the agent and come back, and a Harness that exits when it is asked to — and no
    /// wider. A Harness that ignores its termination signal is killed a moment later by the teardown that
    /// signalled it, but that is longer than anyone should be kept waiting on a quit, so the drain gives
    /// up here and lets the app go: bounded, and never a hang.
    static let shutdownDrain: Duration = .seconds(5)

    /// How long the drain waits between looks.
    static let drainPoll: Duration = .milliseconds(50)

    /// How many times the drain looks before giving up — the bound, expressed in looks rather than in
    /// wall time so that it holds however the clock behind it runs.
    private static let drainAttempts = Int(shutdownDrain / drainPoll)

    /// Stops every open Workflow's agents and waits, briefly, for them to actually come down. What
    /// quitting defers termination for.
    ///
    /// Until a tool could block on a question, every Turn ended on its own, so a Harness orphaned by a
    /// quit was a bounded waste and nothing worse. A Turn suspended in a question ends only when something
    /// ends it: quit with one on screen and the `claude` process it is blocked inside outlives the app,
    /// holding a conversation nobody can see or answer. So this asks, and then waits for the asking to
    /// have taken effect, rather than asking and leaving.
    ///
    /// What it waits on is ``WorkflowContainerModel/hasWorkInFlight`` rather than `isRunning`, which a
    /// stop clears eagerly so the UI can reflect it at once. Quitting on `isRunning` would be quitting on
    /// the UI's word for it and orphaning the Harness a moment later.
    ///
    /// Every Workflow is asked before any of them is waited on, so several come down together against the
    /// one drain rather than one behind another.
    public func shutDownEverything() async {
        @Dependency(\.continuousClock) var clock
        let workflows = openModels
        for workflow in workflows { workflow.stopAll() }

        for _ in 0..<Self.drainAttempts {
            guard workflows.contains(where: \.hasWorkInFlight) else { return }
            do { try await clock.sleep(for: Self.drainPoll) } catch { return }
        }
    }

    /// The models of the windows still open, in no particular order — nothing here waits on anything.
    private var openModels: [WorkflowContainerModel] {
        openWindows.values.compactMap(\.model)
    }
}
