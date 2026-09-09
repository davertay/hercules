import Agent
import Foundation
import Observation

/// One `ask_user` call as the user answers it: the questions it asked, the answer being composed for
/// each, and the control that ends it.
///
/// It is a live affordance, not a Transcript row. It exists only while a call is actually waiting on it
/// and it goes the moment that call is answered, while the Transcript records the `tool_use` and its
/// `tool_result` separately, through the generic path every other tool takes. So *answerable* means "it
/// is the card" and *history* means "it is a row": there is no third state in which a row might still be
/// answerable, the read-only transcript view has nothing to render, and a reopened Workflow has nothing
/// to resurrect.
@MainActor
@Observable
final class PendingQuestion: Identifiable {
    let id: UUID

    /// The questions of one call. Usually one — asking one at a time is a Skill's convention — but the
    /// schema allows several, and one answer covers the whole call.
    let questions: [Question]

    /// The answer being composed for each question, index-aligned with ``questions``.
    var drafts: [Draft]

    /// What the user picked and what the user typed, held apart.
    ///
    /// They are joined only when the answer is serialised for the wire, and the user never edits a label.
    /// Pre-filling an editable field with the label would destroy the exact match and leave the model
    /// comparing its own words back to itself by eye.
    struct Draft: Equatable, Sendable {
        /// The labels picked, verbatim as the model wrote them.
        var selected: [String] = []
        /// What the user typed alongside the selection — a qualification of it, or, with nothing
        /// selected, the whole answer.
        var note: String = ""

        var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Resumes the call waiting on this question, and is cleared as it is used: a call gets one answer.
    private var complete: ((Answer) -> Void)?

    /// Stops the Turn that asked, once the call has been told the user declined — the second half of
    /// ``cancel()``, supplied by the engine because only the engine holds the Turn.
    private let onCancel: () -> Void

    init(
        id: UUID = UUID(),
        questions: [Question],
        onCancel: @escaping () -> Void = {},
        complete: @escaping (Answer) -> Void
    ) {
        self.id = id
        self.questions = questions
        self.drafts = Array(repeating: Draft(), count: questions.count)
        self.onCancel = onCancel
        self.complete = complete
    }

    func isSelected(_ label: String, at index: Int) -> Bool {
        drafts[index].selected.contains(label)
    }

    /// Picks or unpicks `label` for the question at `index`. A multi-select question accumulates its
    /// picks, in the order the model listed the options rather than the order they were clicked; any
    /// other question replaces its pick.
    ///
    /// Picking the current selection again clears it, because "nothing selected, note filled" is a real
    /// answer — the note alone — rather than an unfinished one. That is the whole of "Other", collapsed
    /// into the general case instead of given a button of its own.
    func toggle(_ label: String, at index: Int) {
        var chosen = Set(drafts[index].selected)
        if chosen.contains(label) {
            chosen.remove(label)
        } else if questions[index].multiSelect {
            chosen.insert(label)
        } else {
            chosen = [label]
        }
        drafts[index].selected = questions[index].options.map(\.label).filter(chosen.contains)
    }

    /// Whether there is an answer to send. Every question needs a pick or something typed; nothing picked
    /// and nothing typed is the one row of the table with no answer in it, so Submit refuses it.
    var canSubmit: Bool {
        drafts.allSatisfy { !$0.selected.isEmpty || !$0.trimmedNote.isEmpty }
    }

    /// The answer as the agent receives it: the picked labels exactly as it worded them, and the note as
    /// a field of its own, dropped when there is nothing in it.
    var answer: [QuestionAnswer] {
        zip(questions, drafts).map { question, draft in
            QuestionAnswer(
                header: question.header,
                selected: draft.selected,
                note: draft.trimmedNote.isEmpty ? nil : draft.trimmedNote
            )
        }
    }

    func submit() {
        guard canSubmit else { return }
        resolve(.answered(answer))
    }

    /// Declines the question without answering it, and stops the Turn that asked it.
    ///
    /// It is *Cancel* rather than *Skip*, deliberately. Skip says the agent carries on without an answer,
    /// which is the guessing this whole feature exists to prevent; Cancel says the question and the work
    /// waiting on it both stop here.
    ///
    /// The two steps are in that order and the order is the point. The call is answered first — with the
    /// dismissal, which the tool returns flagged as an error — so it comes back on its own and the
    /// Harness records a complete call-and-result pair. Only then does the Turn go. Answering alone would
    /// not do: a model has been observed retrying a failed call, and a question the user has just
    /// declined bouncing straight back as a second card is what a control labelled Cancel must never do.
    func cancel() {
        resolve(.cancelled)
        onCancel()
    }

    /// Ends the call with `answer`, once. Beyond ``submit()`` this is how the engine dismisses a card
    /// whose Turn has ended without the call coming back for its answer.
    func resolve(_ answer: Answer) {
        guard let complete else { return }
        self.complete = nil
        complete(answer)
    }
}
