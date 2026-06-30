import SwiftUI

/// The scrolling conversation, a composable unit with no window chrome — a non-chat-only host can
/// embed just this as a panel.
public struct ChatTranscript: View {
    let engine: ChatEngine

    public init(engine: ChatEngine) {
        self.engine = engine
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(engine.messages) { message in
                        ChatMessageBubble(message: message)
                    }
                    if let errorText = engine.errorText {
                        ChatMessageBubble(
                            message: Message(
                                id: "error",
                                kind: .assistant,
                                text: errorText,
                                isError: true
                            )
                        )
                    }
                    if engine.isRunning {
                        ChatRunningIndicator()
                    }
                    Spacer()
                        .frame(height: 6)
                        .id("bottom")
                }
                .padding()
            }
            .onChange(of: engine.messages.count) { _, _ in scrollToBottom(proxy: proxy) }
            .onChange(of: engine.isRunning) { _, _ in scrollToBottom(proxy: proxy) }
        }
    }

    // The documented `.defaultScrollAnchor` modifiers do not work here, so we scroll to a pinned
    // bottom anchor instead.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

struct ChatMessageBubble: View {
    let message: Message
    /// Forwarded to `ToolResultRow`. Defaults to the live chat's 8-line cap; the read-only transcript
    /// view passes `nil` to show tool results in full.
    var toolResultLineLimit: Int? = 8

    var body: some View {
        switch message.kind {
        case .user, .assistant:
            chatBubble
        case .thinking:
            ThinkingRow(text: message.text)
        case .toolUse:
            ToolCallRow(name: message.toolName ?? "tool", input: message.text)
        case .toolResult:
            ToolResultRow(text: message.text, lineLimit: toolResultLineLimit)
        }
    }

    private var chatBubble: some View {
        HStack(alignment: .top) {
            if message.kind == .user { Spacer(minLength: 60) }
            bubbleContent
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if message.kind == .assistant { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                renderedMarkdown(message.text)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } else if message.kind == .assistant {
            renderedMarkdown(message.text)
                .textSelection(.enabled)
        } else {
            Text(message.text)
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
    }

    private var bubbleBackground: Color {
        switch (message.kind, message.isError) {
        case (_, true): return Color(.controlBackgroundColor)
        case (.user, _): return .accentColor
        default: return Color(.controlBackgroundColor)
        }
    }

    private func renderedMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

struct ThinkingRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct ToolCallRow: View {
    let name: String
    let input: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.weight(.semibold).monospaced())
                if !input.isEmpty {
                    Text(input)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Truncated so a long read/search doesn't flood the chat. `lineLimit` defaults to 8 for the live
/// chat; the read-only transcript view passes `nil` to show tool results in full.
struct ToolResultRow: View {
    let text: String
    var lineLimit: Int? = 8

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
    }
}

private struct ChatRunningIndicator: View {
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
