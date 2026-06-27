import Store
import SwiftUI

/// A halt banner above the graph when a run stopped on a failed Issue: names the Issue, lets the user
/// jump to it, and offers a one-tap retry that resumes the run from there.
struct HaltBanner: View {
    let issue: IssueRow
    let reason: String?
    let onSelect: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run halted at Issue #\(issue.number) — \(issue.title)")
                    .font(.callout.weight(.semibold))
                if let reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Show", action: onSelect)
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.12))
    }
}
