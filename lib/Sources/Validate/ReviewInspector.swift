import Chat
import SQLiteData
import UISupport
import Store
import SwiftUI

struct ReviewInspector: View {
    let persona: ReviewPersona?
    let review: ReviewRow?
    /// The per-Workflow Store the reviewer run was projected into, read by the diagnostic `TranscriptView`.
    let transcriptDatabase: any DatabaseReader

    @State private var showingTranscript = false

    /// The selected Persona's reviewer Session, or `nil` until it has run. The same value gates the "View
    /// transcript" button and supplies the sheet's subject, so the two can't disagree.
    private var transcriptSession: UUID? { review?.sessionID }

    var body: some View {
        if let persona {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(persona.title)
                        .font(.title3.weight(.semibold))
                    let status = review.flatMap { ReviewStatus(rawValue: $0.status) }
                    LabeledContent("Status") { Text(label(for: status)) }
                        .font(.callout)
                    Button {
                        showingTranscript = true
                    } label: {
                        Label("View transcript", systemImage: "text.bubble")
                    }
                    .disabled(transcriptSession == nil)
                    .help(transcriptSession == nil
                        ? "No transcript yet — run this review"
                        : "Open this Persona's review transcript")
                    Divider()
                    Text(persona.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if status == .failed, let reason = review?.failureReason {
                        FailureCallout(reason: reason)
                    }
                    if let summary = review?.summary, !summary.isEmpty {
                        Divider()
                        Text("Summary")
                            .font(.callout.weight(.semibold))
                        MarkdownText(summary)
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
                        persona: persona,
                        sessionID: transcriptSession,
                        database: transcriptDatabase
                    )
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Persona selected", systemImage: "sidebar.right")
            } description: {
                Text("Select a Persona to see its review Summary.")
            }
        }
    }
}

/// One Persona's reviewer-run transcript, presented as a sheet. Read-only chrome: a Done button
/// top-trailing — also bound to Escape — over a resizable frame with sensible minimums. It holds no state
/// of its own, so size and scroll start fresh on each open.
private struct TranscriptSheet: View {
    let persona: ReviewPersona
    let sessionID: UUID
    let database: any DatabaseReader

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TranscriptView(sessionID: sessionID, database: database)
                .navigationTitle("\(persona.title) review")
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

private func label(for status: ReviewStatus?) -> String {
    switch status {
    case .none: "Not run"
    case .running: "Reviewing…"
    case .reviewed: "Reviewed"
    case .failed: "Failed"
    }
}
