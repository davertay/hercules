import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

public struct DesignView: View {
    @Bindable var model: DesignModel

    public init(model: DesignModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isIntake {
                IntakeView()
            } else {
                transcript
            }
            if let savedURL = model.summarySavedURL {
                Divider()
                DesignSummarySavedBanner(url: savedURL)
            }
            Divider()
            DesignComposer(model: model)
        }
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle("Design")
        .toolbar {
            if model.isGenerateSummaryAvailable {
                ToolbarItem {
                    Button("Generate Design Summary", systemImage: "doc.text") {
                        model.generateSummary()
                    }
                    .disabled(model.isRunning)
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        DesignMessageBubble(message: message, onSelectOption: { option in
                            model.draftText = option
                            model.submit()
                        })
                    }
                    if let errorText = model.errorText {
                        DesignMessageBubble(
                            message: DesignModel.Message(
                                id: "error",
                                kind: .assistant,
                                text: errorText,
                                isError: true
                            )
                        )
                    }
                    if model.isRunning {
                        DesignRunningIndicator()
                    }
                    Spacer()
                        .frame(height: 6)
                        .id("bottom")
                }
                .padding()
            }
            .onChange(of: model.messages.count) { _, _ in scrollToBottom(proxy: proxy) }
            .onChange(of: model.isRunning) { _, _ in scrollToBottom(proxy: proxy) }
        }
    }

    // See TestChatView: the documented `.defaultScrollAnchor` modifiers do not work here, so we
    // scroll to a pinned bottom anchor instead.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

private struct IntakeView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("What are we building today?")
                .font(.title)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DesignComposer: View {
    @Bindable var model: DesignModel
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
        .onAppear { isFocused = true }
        .onChange(of: model.isRunning) { _, isRunning in
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
        model.isSendDisabled ? .secondary : .accentColor
    }
}

private struct DesignMessageBubble: View {
    let message: DesignModel.Message
    var onSelectOption: (String) -> Void = { _ in }

    var body: some View {
        switch message.kind {
        case .user, .assistant:
            chatBubble
        case .thinking:
            ThinkingRow(text: message.text)
        case .toolUse:
            if message.toolName == "AskUserQuestion" {
                AskUserQuestionRow(text: message.text, onSelectOption: onSelectOption)
            } else {
                ToolCallRow(name: message.toolName ?? "tool", input: message.text)
            }
        case .toolResult:
            ToolResultRow(text: message.text)
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

/// The agent's thinking, shown as a subdued italic aside distinct from its spoken text.
private struct ThinkingRow: View {
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

/// One step in the live tool-call timeline: the tool's name and the JSON input it was invoked with.
private struct ToolCallRow: View {
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

/// A tool's result, rendered monospaced and truncated so a long read/search doesn't flood the chat.
private struct ToolResultRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
    }
}

/// Confirmation that the Design summary was saved, with a Reveal in Finder button. The user edits
/// the markdown externally; the app never renders or edits it in place.
private struct DesignSummarySavedBanner: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Design summary saved")
                    .font(.callout.weight(.medium))
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            #if canImport(AppKit)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DesignRunningIndicator: View {
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

/// An interactive question card rendered when the agent calls `AskUserQuestion`. Each option is a
/// tappable button that submits the selection label back into the conversation.
private struct AskUserQuestionRow: View {
    let text: String
    let onSelectOption: (String) -> Void

    private struct Payload: Decodable {
        struct Question: Decodable {
            let header: String
            let question: String
            let multiSelect: Bool
            let options: [Option]
            struct Option: Decodable {
                let label: String
                let description: String?
            }
        }
        let questions: [Question]
    }

    private var questions: [Payload.Question] {
        guard
            let data = text.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [] }
        return payload.questions
    }

    var body: some View {
        if questions.isEmpty {
            ToolCallRow(name: "AskUserQuestion", input: text)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(question.header)
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                        }
                        Text(question.question)
                            .font(.callout)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                                Button {
                                    onSelectOption(option.label)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                            .font(.callout.weight(.medium))
                                        if let description = option.description, !description.isEmpty {
                                            Text(description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.windowBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
