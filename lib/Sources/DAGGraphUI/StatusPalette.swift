import IssueGraph
import SwiftUI

/// Colours for `IssueStatus`, centralised so every DAG view renders status the same way.
public struct StatusPalette: Sendable {
    public let pending: Color
    public let ready: Color
    public let inProgress: Color
    public let complete: Color
    public let failed: Color
    /// HITL Proposed Issues — distinct from the run-lifecycle colours so they read as "awaiting approval".
    public let proposed: Color

    public init(
        pending: Color,
        ready: Color,
        inProgress: Color,
        complete: Color,
        failed: Color,
        proposed: Color = .purple
    ) {
        self.pending = pending
        self.ready = ready
        self.inProgress = inProgress
        self.complete = complete
        self.failed = failed
        self.proposed = proposed
    }

    public static let `default` = StatusPalette(
        pending: .blue,
        ready: .yellow,
        inProgress: .orange,
        complete: .green,
        failed: .red,
        proposed: .purple
    )

    /// `.skipped` reuses the pending grey — the view's slash overlay carries the skipped cue.
    public func color(for status: IssueStatus) -> Color {
        switch status {
        case .pending: pending
        case .ready: ready
        case .inProgress: inProgress
        case .done: complete
        case .failed: failed
        case .skipped: pending
        case .proposed: proposed
        }
    }

    /// `.white` on the saturated fills, `.primary` on the neutral pending/skipped grey.
    public func foregroundColor(for status: IssueStatus) -> Color {
        switch status {
        case .pending: .primary
        case .ready: .white
        case .inProgress: .white
        case .done: .white
        case .failed: .white
        case .skipped: .primary
        case .proposed: .white
        }
    }
}
