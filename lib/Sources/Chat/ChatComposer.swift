import SwiftUI

/// The message input: a vertically-growing text field plus a send button. A composable unit a host
/// places wherever its layout calls for it. Carries no window chrome.
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
            // Drop focus while the Turn runs (the field is disabled), then restore it once the Turn
            // ends. Defer the re-focus to the next runloop tick so it lands *after* the field is
            // re-enabled: assigning @FocusState in the same pass the field re-enables races AppKit
            // and leaves the binding stuck `true` while the field is actually unfocusable, which is
            // why clicking the field couldn't recover focus.
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
