import SwiftUI

public struct TestChatView: View {
    @Bindable var model: TestChatModel

    public init(model: TestChatModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if model.isRunning {
                            RunningIndicator()
                                .id("running")
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: model.isRunning) { _, isRunning in
                    if isRunning {
                        withAnimation { proxy.scrollTo("running", anchor: .bottom) }
                    } else if let last = model.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            Composer(model: model)
        }
        .frame(minWidth: 500, minHeight: 400)
        .onDisappear {
            model.tearDown()
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if model.isRunning {
            withAnimation { proxy.scrollTo("running", anchor: .bottom) }
        } else if let last = model.messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

private struct RunningIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking…")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Composer: View {
    @Bindable var model: TestChatModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $model.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
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
            .disabled(isSendDisabled)
        }
        .padding(12)
    }

    private var isSendDisabled: Bool {
        model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning
    }

    private var sendButtonForeground: Color {
        isSendDisabled ? .secondary : .accentColor
    }
}

private struct MessageBubble: View {
    let message: TestChatModel.ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 60) }
            bubbleContent
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } else if message.role == .assistant {
            renderedMarkdown(message.text)
                .textSelection(.enabled)
        } else {
            Text(message.text)
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
    }

    private var bubbleBackground: Color {
        switch (message.role, message.isError) {
        case (_, true): return Color(.controlBackgroundColor)
        case (.user, _): return .accentColor
        case (.assistant, _): return Color(.controlBackgroundColor)
        }
    }

    private func renderedMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }
}
