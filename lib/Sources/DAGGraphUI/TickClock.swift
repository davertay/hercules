import Dependencies
import Foundation
import Observation

/// The once-a-second wall-clock tick behind the live elapsed readout the DAG surfaces render
/// (`NodeActivity`'s `clock`). One instance per surface, started only while a run is underway — an
/// idle surface runs no timer at all. `stop()` is nonisolated so a window's teardown can cancel it
/// from any isolation.
@MainActor
@Observable
public final class TickClock {
    /// The latest tick; `.distantPast` until the clock first starts.
    public private(set) var now: Date = .distantPast

    @ObservationIgnored
    private let tickTask = LockIsolated<Task<Void, Never>?>(nil)

    @ObservationIgnored
    @Dependency(\.date.now) private var currentDate

    public init() {}

    /// Re-anchors `now` immediately and begins ticking. Starting an already-ticking clock just
    /// re-anchors it — the running timer is kept (Validate starts on every Persona run).
    public func start() {
        now = currentDate
        guard tickTask.value == nil else { return }
        let task = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = currentDate
            }
        }
        tickTask.setValue(task)
    }

    public nonisolated func stop() {
        tickTask.value?.cancel()
        tickTask.setValue(nil)
    }
}
