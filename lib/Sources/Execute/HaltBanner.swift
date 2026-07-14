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

/// Occupies the same slot as `HaltBanner`, but for a run that hit the account's session limit and is
/// waiting it out rather than giving up: names the Issue it will re-run, shows the absolute resume time,
/// and lets the user jump to the paused node. There's no button — Stop (the toolbar control) is the
/// escape hatch — and no red, because we haven't failed, just paused.
struct ResumeBanner: View {
    let issue: IssueRow
    let resumingAt: Date
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session limit reached — resuming automatically at \(resumingAt.formatted(date: .omitted, time: .shortened))")
                    .font(.callout.weight(.semibold))
                Text("Issue #\(issue.number) — \(issue.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Show", action: onSelect)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}

#if DEBUG
private func previewIssue(_ number: Int, _ title: String) -> IssueRow {
    IssueRow(id: UUID(), workflowID: UUID(), number: number, title: title, createdAt: .now, updatedAt: .now)
}

#Preview("Halt (failed)") {
    HaltBanner(
        issue: previewIssue(6, "Wire end-to-end"),
        reason: "The agent produced no commit and made no changes.",
        onSelect: {},
        onRetry: {}
    )
    .frame(width: 640)
    .padding()
}

#Preview("Resuming (session limit)") {
    ResumeBanner(
        issue: previewIssue(6, "Wire end-to-end"),
        resumingAt: Calendar.current.date(bySettingHour: 19, minute: 11, second: 0, of: .now) ?? .now,
        onSelect: {}
    )
    .frame(width: 640)
    .padding()
}
#endif
