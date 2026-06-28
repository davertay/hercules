import Foundation
import Observation

/// Tracks which Workflows currently have an open window — open-vs-closed only, deliberately not live busy
/// state and with no DB heartbeat. The launcher consults it to disable its per-row destroy button while a
/// window is open for that Workflow; you destroy from that window's idle-gated toolbar button instead.
@MainActor
@Observable
public final class OpenWorkflowRegistry {
    private var openIDs: Set<UUID> = []

    public init() {}

    /// Records that a window is now open for `id`. Idempotent.
    public func register(_ id: UUID) {
        openIDs.insert(id)
    }

    /// Schedules a ``register(_:)`` off the current run-loop turn. A Workflow window's model constructs
    /// during SwiftUI's view-graph update (inside `State`'s initial value), so mutating this observed state
    /// synchronously there re-enters the launcher's display cycle and AppKit throws an "Update Constraints"
    /// exception. Deferring the mutation past the active update — mirroring ``unregisterOnTeardown(_:)`` —
    /// keeps the write out of that cycle.
    public func registerOnOpen(_ id: UUID) {
        Task { @MainActor in self.register(id) }
    }

    /// Records that the window for `id` has closed. Idempotent.
    public func unregister(_ id: UUID) {
        openIDs.remove(id)
    }

    /// Whether a window is currently open for `id`.
    public func isOpen(_ id: UUID) -> Bool {
        openIDs.contains(id)
    }

    /// Schedules an ``unregister(_:)`` from a `nonisolated` context — a Workflow window's model unregisters
    /// here from its deinitializer, which can't synchronously touch this main-actor state.
    public nonisolated func unregisterOnTeardown(_ id: UUID) {
        Task { @MainActor in self.unregister(id) }
    }
}
