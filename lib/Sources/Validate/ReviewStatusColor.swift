import Store
import SwiftUI

/// Lifecycle colours for a review node, local to Validate rather than reusing `StatusPalette` (which is
/// keyed to `IssueStatus`). Idle (no row) is gray; there is no terminal green — reviewers hold the latest
/// Summary and stay re-runnable, so `reviewed` is indigo.
enum ReviewStatusColor {
    static func color(for status: ReviewStatus?) -> Color {
        switch status {
        case .none: .secondary
        case .running: .orange
        case .reviewed: .indigo
        case .failed: .red
        }
    }

    /// The short status label shown under the card title and in the inspector.
    static func label(for status: ReviewStatus?) -> String {
        switch status {
        case .none: "Not run"
        case .running: "Reviewing…"
        case .reviewed: "Reviewed"
        case .failed: "Failed"
        }
    }
}
