import Chat
import DAGGraphUI
import IssueGraph
import SQLiteData
import Store
import SwiftUI
import UISupport

struct InspectorPane: View {
    let issue: IssueRow?
    let failureReason: String?
    let lastTurnAnswer: String?
    let transcriptSession: SessionRow?
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
                        Spacer()
                        Text(issue.statusText)
                            .font(.callout)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(issue.statusColor.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
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
                    if let lastTurnAnswer {
                        Divider()
                        MarkdownText(lastTurnAnswer)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        MarkdownText(issue.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !issue.body.isEmpty {
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

fileprivate extension IssueRow {
    var statusColor: Color {
        StatusPalette.default.color(for: mapStatus(status))
    }

    var statusText: String {
        status.capitalized.replacingOccurrences(of: "_", with: " ")
    }
}

#if DEBUG

#Preview("No Issue") {
    InspectorPane(
        issue: nil,
        failureReason: nil,
        lastTurnAnswer: nil,
        transcriptSession: nil,
        transcriptDatabase: try! defaultDatabase(),
        onRetry: { _ in },
        onApprove: { _ in },
        onDeny: { _ in }
    )
}

#Preview("Empty") {
    InspectorPane(
        issue: IssueRow(
            id: UUID(),
            workflowID: UUID(),
            number: 3,
            title: "No Issue Content",
            status: "new",
            createdAt: Date(),
            updatedAt: Date()
        ),
        failureReason: nil,
        lastTurnAnswer: nil,
        transcriptSession: nil,
        transcriptDatabase: try! defaultDatabase(),
        onRetry: { _ in },
        onApprove: { _ in },
        onDeny: { _ in }
    )
}

#Preview("Ready") {
    InspectorPane(
        issue: IssueRow(
            id: UUID(),
            workflowID: UUID(),
            number: 5,
            title: "General Improvements",
            body: """
            ## What to build
            Do whatever it takes to make the app better.
            """,
            dependencies: [2,3],
            status: "ready",
            createdAt: Date(),
            updatedAt: Date()
        ),
        failureReason: nil,
        lastTurnAnswer: nil,
        transcriptSession: nil,
        transcriptDatabase: try! defaultDatabase(),
        onRetry: { _ in },
        onApprove: { _ in },
        onDeny: { _ in }
    )
}

#Preview("Done") {
    InspectorPane(
        issue: IssueRow(
            id: UUID(),
            workflowID: UUID(),
            number: 5,
            title: "General Improvements",
            body: """
            ## What to build
            Do whatever it takes to make the app better.
            """,
            dependencies: [2,3],
            status: "done",
            createdAt: Date(),
            updatedAt: Date()
        ),
        failureReason: nil,
        lastTurnAnswer: """
            ## What I did
            I made the app better.
            """,
        transcriptSession: nil,
        transcriptDatabase: try! defaultDatabase(),
        onRetry: { _ in },
        onApprove: { _ in },
        onDeny: { _ in }
    )
}

#Preview("Failed") {
    InspectorPane(
        issue: IssueRow(
            id: UUID(),
            workflowID: UUID(),
            number: 5,
            title: "General Improvements",
            body: """
            ## What to build
            Do whatever it takes to make the app better.
            """,
            dependencies: [2,3],
            status: "failed",
            createdAt: Date(),
            updatedAt: Date()
        ),
        failureReason: "Everything is broken",
        lastTurnAnswer: nil,
        transcriptSession: nil,
        transcriptDatabase: try! defaultDatabase(),
        onRetry: { _ in },
        onApprove: { _ in },
        onDeny: { _ in }
    )
}

#Preview("Proposed") {
    InspectorPane(
        issue: IssueRow(
            id: UUID(),
            workflowID: UUID(),
            number: 5,
            title: "Sketchy Idea",
            body: """
            ## Something Dubious
            Probaly don't want this one.
            """,
            status: "proposed",
            createdAt: Date(),
            updatedAt: Date()
        ),
        failureReason: nil,
        lastTurnAnswer: nil,
        transcriptSession: nil,
        transcriptDatabase: try! defaultDatabase(),
        onRetry: { _ in },
        onApprove: { _ in },
        onDeny: { _ in }
    )
}

#endif
