import SwiftUI

/// A ready-made transcript-over-composer chat for chat-only hosts. Hosts that interleave their own UI
/// compose `ChatTranscript` and `ChatComposer` directly instead.
public struct ChatView: View {
    let engine: ChatEngine

    public init(engine: ChatEngine) {
        self.engine = engine
    }

    public var body: some View {
        VStack(spacing: 0) {
            ChatTranscript(engine: engine)
            Divider()
            ChatComposer(engine: engine)
        }
    }
}
