import Foundation
import SQLiteData
import SwiftUI

/// A read-only view of one run's transcript, scoped to a single Session. It renders the same shared
/// bubbles as the live `ChatTranscript`, but bare: no composer, no send, no running spinner, no
/// auto-scroll — those are chat-driver niceties tied to `ChatEngine.isRunning`, which this view does
/// not have. Because it observes the Workflow database through a reactive `@Fetch`, content appends
/// live when opened on a still-running run, and tool results are shown in full (no line cap) since
/// this is a diagnostic surface.
public struct TranscriptView: View {
    @Fetch private var conversation: ConversationRequest.Value

    /// `sessionID` is the run's Session — the `execute` Session of an Issue or the `validate` Session
    /// behind a Persona's Review. `database` is the per-Workflow Store the run was projected into.
    public init(sessionID: UUID, database: any DatabaseReader) {
        _conversation = Fetch(
            wrappedValue: ConversationRequest.Value(),
            ConversationRequest(sessionID: sessionID),
            database: database,
            animation: .default
        )
    }

    public var body: some View {
        if conversation.turns.isEmpty {
            // The Session row exists but the agent threw before any Turn was recorded; the failure
            // reason already shows in the inspector, so a one-line note is enough here.
            Text("No transcript recorded for this run.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        ChatMessageBubble(message: message, toolResultLineLimit: nil)
                    }
                }
                .padding()
            }
        }
    }

    /// Built from the shared `transcriptMessages` so this view and the live chat can't drift apart.
    private var messages: [Message] {
        transcriptMessages(turns: conversation.turns, blocks: conversation.blocks)
    }
}
