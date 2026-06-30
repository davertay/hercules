import Chat
import SQLiteData
import UISupport
import Store
import SwiftUI

struct InspectorPane: View {
    let issue: IssueRow?
    let failureReason: String?
    /// The latest `execute` Session for the selected Issue, or `nil` if it has never run. Handed to the
    /// shared `TranscriptViewerButton`, which gates on it.
    let transcriptSession: SessionRow?
    /// The per-Workflow Store the run was projected into, read by the diagnostic `TranscriptView`.
    let transcriptDatabase: any DatabaseReader
    let onRetry: (Int) -> Void
    let onApprove: (Int) -> Void
    let onDeny: (Int) -> Void

    private var isFailed: Bool { issue?.status == IssueRunStatus.failed.rawValue }
    private var isProposed: Bool { issue?.status == "proposed" }

    var body: some View {
        if let issue {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#\(issue.number)")
                            .font(.title3.weight(.semibold).monospaced())
                            .foregroundStyle(.secondary)
                        Text(issue.title)
                            .font(.title3.weight(.semibold))
                    }
                    LabeledContent("Status") { Text(issue.status) }
                        .font(.callout)
                    if !issue.dependencies.isEmpty {
                        LabeledContent("Depends on") {
                            Text(issue.dependencies.map { "#\($0)" }.joined(separator: ", "))
                        }
                        .font(.callout)
                    }
                    TranscriptViewerButton(
                        title: "Issue #\(issue.number) — \(issue.title)",
                        sessionID: transcriptSession?.id,
                        database: transcriptDatabase,
                        unavailableHelp: "No transcript yet — run this Issue",
                        availableHelp: "Open the latest executor run's transcript"
                    )
                    if isProposed {
                        ProposalCallout(
                            onApprove: { onApprove(issue.number) },
                            onDeny: { onDeny(issue.number) }
                        )
                    }
                    if isFailed {
                        FailureCallout(reason: failureReason) {
                            onRetry(issue.number)
                        }
                    }
                    if !issue.body.isEmpty {
                        Divider()
                        MarkdownText(issue.body)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("No Issue selected", systemImage: "sidebar.right")
            } description: {
                Text("Select a node in the graph to see its details.")
            }
        }
    }
}
