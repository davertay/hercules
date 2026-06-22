import SwiftUI

/// The message input: a vertically-growing text field plus a send button. A composable unit with no
/// window chrome.
public struct ChatComposer: View {
    @Bindable var engine: ChatEngine
    @FocusState private var isFocused: Bool

    public init(engine: ChatEngine) {
        self.engine = engine
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $engine.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isFocused)
                .disabled(engine.isRunning)
                .onSubmit { engine.submit() }
            Button {
                engine.submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(sendButtonForeground)
            }
            .buttonStyle(.plain)
            .disabled(engine.isSendDisabled)
        }
        .padding(12)
        .onAppear { isFocused = true }
        .onChange(of: engine.isRunning) { _, isRunning in
            // Defer the re-focus a tick so it lands *after* the field re-enables; assigning
            // @FocusState in the same pass races AppKit and leaves the binding stuck unfocusable.
            if isRunning {
                isFocused = false
            } else {
                Task { @MainActor in isFocused = true }
            }
        }
    }

    private var sendButtonForeground: Color {
        engine.isSendDisabled ? .secondary : .accentColor
    }
}
