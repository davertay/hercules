import IssueGraph
import SwiftUI

/// Colours for `IssueStatus`, centralised so every consumer of the DAG views renders status the same
/// way. Ported from the prototype's `Theme.StatusPalette` and retargeted from `TicketStatus` to
/// `IssueStatus` (`green`→`done`).
public struct StatusPalette: Sendable {
    public let pending: Color
    public let ready: Color
    public let inProgress: Color
    public let complete: Color
    public let failed: Color

    public init(
        pending: Color,
        ready: Color,
        inProgress: Color,
        complete: Color,
        failed: Color
    ) {
        self.pending = pending
        self.ready = ready
        self.inProgress = inProgress
        self.complete = complete
        self.failed = failed
    }

    public static let `default` = StatusPalette(
        pending: .secondary,
        ready: .blue,
        inProgress: .orange,
        complete: .green,
        failed: .red
    )

    /// Canonical colour for a given `IssueStatus`: gray pending, blue ready, amber in-progress, green
    /// done, red failed, gray skipped (the view applies a slash overlay for the "skipped" cue, so the
    /// colour itself matches `.pending`).
    public func color(for status: IssueStatus) -> Color {
        switch status {
        case .pending: pending
        case .ready: ready
        case .inProgress: inProgress
        case .done: complete
        case .failed: failed
        case .skipped: pending
        }
    }

    /// Legible label colour for text drawn on top of `color(for:)`. Two buckets, partitioned by
    /// background luminance: `.white` on the saturated fills (ready/inProgress/done/failed), `.primary`
    /// (SwiftUI's auto-inverting label colour) on the neutral pending/skipped grey.
    public func foregroundColor(for status: IssueStatus) -> Color {
        switch status {
        case .pending: .primary
        case .ready: .white
        case .inProgress: .white
        case .done: .white
        case .failed: .white
        case .skipped: .primary
        }
    }
}
