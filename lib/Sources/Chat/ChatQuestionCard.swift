import Agent
import SwiftUI

/// The live question card: the options the agent offered, with the descriptions it wrote for them, and
/// one always-visible note field whose meaning follows from what is picked.
///
/// | Picked | Note | Answer sent |
/// |---|---|---|
/// | an option | empty | the label |
/// | an option | filled | the label *plus* the note |
/// | none | filled | the note alone — this *is* "Other" |
/// | none | empty | cannot submit |
///
/// The note is one field rather than a separate "Other" option, which makes *that option, but with this
/// tweak* a first-class answer rather than an escape hatch — the whole reason this beats retyping the
/// answer as prose. There is no composer to fall back to: the Turn is still running, so it stays locked
/// and the running indicator stays up, and a typed message could not become this call's `tool_result`
/// anyway.
struct ChatQuestionCard: View {
    @Bindable var pending: PendingQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(pending.questions.enumerated()), id: \.offset) { index, question in
                questionSection(question, at: index)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Submit") { pending.submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!pending.canSubmit)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.5))
        }
    }

    @ViewBuilder
    private func questionSection(_ question: Question, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !question.options.isEmpty {
                    Text(question.multiSelect ? "Choose any that apply" : "Choose one")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(question.question)
                .font(.callout)
                .textSelection(.enabled)
            ForEach(question.options, id: \.label) { option in
                optionRow(option, of: question, at: index)
            }
            TextField(notePlaceholder(at: index), text: $pending.drafts[index].note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
        }
    }

    /// The label is a control, never a text field: what the user picks reaches the agent exactly as the
    /// agent worded it, so it can be matched rather than interpreted.
    private func optionRow(_ option: Question.Option, of question: Question, at index: Int) -> some View {
        let isSelected = pending.isSelected(option.label, at: index)
        return Button {
            pending.toggle(option.label, at: index)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol(isSelected: isSelected, multiSelect: question.multiSelect))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout.weight(.medium))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(8)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func symbol(isSelected: Bool, multiSelect: Bool) -> String {
        switch (multiSelect, isSelected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }

    /// The field's meaning follows the selection, so its prompt does too.
    private func notePlaceholder(at index: Int) -> String {
        pending.drafts[index].selected.isEmpty
            ? "Answer in your own words…"
            : "Add a note — a tweak to what you picked (optional)"
    }
}

#if DEBUG

#Preview("One question") {
    ChatQuestionCard(
        pending: PendingQuestion(
            questions: [
                Question(
                    header: "Storage",
                    question: "How should offline notes be stored?",
                    options: [
                        Question.Option(label: "Use SQLite", description: "A real database, migrations and all"),
                        Question.Option(label: "Use a flat file", description: "One JSON blob, rewritten on save"),
                    ]
                )
            ],
            complete: { _ in }
        )
    )
    .padding()
    .frame(width: 460)
}

#Preview("Multi-select, no options") {
    ChatQuestionCard(
        pending: PendingQuestion(
            questions: [
                Question(
                    header: "Sync",
                    question: "What should happen to edits made while offline?",
                    multiSelect: true,
                    options: [
                        Question.Option(label: "Last write wins", description: "Simplest, loses concurrent edits"),
                        Question.Option(label: "Keep both", description: "Fork the note and let the user merge"),
                    ]
                ),
                Question(header: "Anything else", question: "Anything I've missed?"),
            ],
            complete: { _ in }
        )
    )
    .padding()
    .frame(width: 460)
}

#endif
