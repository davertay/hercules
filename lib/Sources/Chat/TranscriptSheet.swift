import Foundation
import SQLiteData
import SwiftUI

/// One run's transcript, presented as a sheet. Read-only chrome: a Done button top-trailing — also
/// bound to Escape — over a resizable frame with sensible minimums. It holds no state of its own, so
/// size and scroll start fresh on each open. The `title` names the run's subject (an Issue or a review
/// Persona); everything else is identical across callers.
public struct TranscriptSheet: View {
    let title: String
    let sessionID: UUID
    let database: any DatabaseReader

    @Environment(\.dismiss) private var dismiss

    public init(title: String, sessionID: UUID, database: any DatabaseReader) {
        self.title = title
        self.sessionID = sessionID
        self.database = database
    }

    public var body: some View {
        NavigationStack {
            TranscriptView(sessionID: sessionID, database: database)
                .navigationTitle(title)
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

/// A "View transcript" button that presents the shared `TranscriptSheet`. The optional `sessionID` both
/// gates the button — disabled, showing `unavailableHelp`, until the run has produced a Session — and
/// supplies the sheet's subject once present, so the two can't disagree. The button owns its own
/// presentation state, so callers only describe the run.
public struct TranscriptViewerButton: View {
    let title: String
    let sessionID: UUID?
    let database: any DatabaseReader
    let unavailableHelp: String
    let availableHelp: String

    @State private var showingTranscript = false

    public init(
        title: String,
        sessionID: UUID?,
        database: any DatabaseReader,
        unavailableHelp: String,
        availableHelp: String
    ) {
        self.title = title
        self.sessionID = sessionID
        self.database = database
        self.unavailableHelp = unavailableHelp
        self.availableHelp = availableHelp
    }

    public var body: some View {
        Button {
            showingTranscript = true
        } label: {
            Label("View transcript", systemImage: "text.bubble")
        }
        .disabled(sessionID == nil)
        .help(sessionID == nil ? unavailableHelp : availableHelp)
        .sheet(isPresented: $showingTranscript) {
            if let sessionID {
                TranscriptSheet(title: title, sessionID: sessionID, database: database)
            }
        }
    }
}
