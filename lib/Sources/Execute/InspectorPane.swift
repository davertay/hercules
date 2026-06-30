import Chat
import SQLiteData
import UISupport
import Store
import SwiftUI

struct InspectorPane: View {
    let issue: IssueRow?
    let failureReason: String?
    /// The latest `execute` Session for the selected Issue, or `nil` if it has never run. The same value
    /// gates the "View transcript" button and supplies the sheet's subject, so the two can't disagree.
    let transcriptSession: SessionRow?
    /// The per-Workflow Store the run was projected into, read by the diagnostic `TranscriptView`.
    let transcriptDatabase: any DatabaseReader
    let onRetry: (Int) -> Void
    let onApprove: (Int) -> Void
    let onDeny: (Int) -> Void

    @State private var showingTranscript = false

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
                    Button {
                        showingTranscript = true
                    } label: {
                        Label("View transcript", systemImage: "text.bubble")
                    }
                    .disabled(transcriptSession == nil)
                    .help(transcriptSession == nil
                        ? "No transcript yet — run this Issue"
                        : "Open the latest executor run's transcript")
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
            .sheet(isPresented: $showingTranscript) {
                if let transcriptSession {
                    TranscriptSheet(
                        issue: issue,
                        sessionID: transcriptSession.id,
                        database: transcriptDatabase
                    )
                }
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

/// The latest executor run's transcript for one Issue, presented as a sheet. Read-only chrome: a Done
/// button top-trailing — also bound to Escape — over a resizable frame with sensible minimums. It holds
/// no state of its own, so size and scroll start fresh on each open.
private struct TranscriptSheet: View {
    let issue: IssueRow
    let sessionID: UUID
    let database: any DatabaseReader

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TranscriptView(sessionID: sessionID, database: database)
                .navigationTitle("Issue #\(issue.number) — \(issue.title)")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
