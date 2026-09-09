import Foundation

/// One question an agent puts to the user, and the options it offers for answering it.
///
/// The shape mirrors the Harness's own `AskUserQuestion` schema field for field — `header`,
/// `question`, `multiSelect`, and `options` of `label`/`description` — so the model reaches for our
/// tool with the prior it already has, at no prompt cost. One call may carry several questions; asking
/// one at a time is a Skill's convention, not a constraint of this type.
public struct Question: Codable, Equatable, Sendable {
    /// The short title the model gives the question, and the key its answer comes back under. The model
    /// authored both, so tying an answer to its question needs nothing we minted.
    public var header: String
    /// The question itself, as the user reads it.
    public var question: String
    /// Whether more than one option may be picked.
    public var multiSelect: Bool
    public var options: [Option]

    public init(header: String, question: String, multiSelect: Bool = false, options: [Option] = []) {
        self.header = header
        self.question = question
        self.multiSelect = multiSelect
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case header, question, multiSelect, options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decode(String.self, forKey: .header)
        question = try container.decode(String.self, forKey: .question)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
    }

    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var description: String

        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }
}

/// The user's reply to one `ask_user` call.
public enum Answer: Codable, Equatable, Sendable {
    /// One entry per question the call asked.
    case answered([QuestionAnswer])
    /// The user dismissed the call without answering.
    case cancelled
}

/// Puts one `ask_user` call's questions to the user and comes back with their reply.
///
/// This is the whole of the seam. A caller supplies one on a ``StartRequest`` or a ``SendRequest``, the
/// Agent invokes it when a Turn's agent asks, and what it returns is delivered back to the call still
/// waiting on it.
///
/// A callback rather than a stream of pending questions because a `send` already doesn't return until
/// the Turn ends, so a blocking question *is* a mid-call callback: correlation is structural — one
/// invocation, one answer — cancellation is returning ``Answer/cancelled``, and a test double is a
/// closure.
///
/// The argument is the questions *one call* asked, not one question, because one ``Answer`` covers the
/// whole call. A call usually carries a single question — asking one at a time is a Skill's convention —
/// but the schema allows several, and splitting them across invocations would put back the correlation
/// this shape removes.
public typealias QuestionHandler = @Sendable ([Question]) async -> Answer

/// The reply to a single ``Question``.
public struct QuestionAnswer: Codable, Equatable, Sendable {
    /// The `header` of the ``Question`` this answers.
    public var header: String
    /// The labels of the options picked, verbatim as the model wrote them. Empty when the user answered
    /// in free text alone.
    public var selected: [String]
    /// What the user typed alongside the selection — a qualification of it, or, with nothing selected,
    /// the whole answer. `nil` when they typed nothing.
    ///
    /// Its own field rather than folded into `selected`, and it stays that way for the whole of the
    /// channel's journey: the two are joined only when the answer is serialised for the wire. Editing a
    /// label to carry the qualification would destroy the exact match the model needs and leave it
    /// comparing strings by eye.
    public var note: String?

    public init(header: String, selected: [String], note: String? = nil) {
        self.header = header
        self.selected = selected
        self.note = note
    }
}
