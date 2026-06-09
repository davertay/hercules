import SwiftUI

/// A ready-made chat for a host that is chat-only: the transcript stacked above the composer with a
/// divider between. Hosts that need to interleave their own UI (an intake prompt, a banner) compose
/// `ChatTranscript` and `ChatComposer` directly instead. Carries no window chrome.
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
