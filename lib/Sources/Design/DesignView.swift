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
                        DesignMessageBubble(message: message)
                    }
                    if let errorText = model.errorText {
                        DesignMessageBubble(
                            message: DesignModel.Message(
                                id: "error",
                                role: .assistant,
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
        .onChange(of: model.isRunning) { _, isRunning in isFocused = !isRunning }
    }

    private var sendButtonForeground: Color {
        model.isSendDisabled ? .secondary : .accentColor
    }
}

private struct DesignMessageBubble: View {
    let message: DesignModel.Message

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
                renderedMarkdown(message.text)
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
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
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
