import SwiftUI

struct Composer: View {
    @Bindable var model: TestChatModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $model.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isFocused)
                .disabled(model.isRunning)
                .onSubmit { model.submit() }
            Button {
                model.submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(sendButtonForeground)
            }
            .buttonStyle(.plain)
            .disabled(model.isSendDisabled)
        }
        .padding(12)
        .onAppear {
            isFocused = true
        }
        .onChange(of: model.isRunning) { _, isRunning in
            isFocused = !isRunning
        }
    }

    private var sendButtonForeground: Color {
        model.isSendDisabled ? .secondary : .accentColor
    }
}
