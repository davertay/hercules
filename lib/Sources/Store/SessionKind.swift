/// The surface a Session serves, persisted so multiple Sessions can share one per-Workflow database
/// without their conversations bleeding into one another (ADR 0005). One Session per (Workflow, kind).
public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case design
    case allocate
    case testChat
    /// A behind-the-scenes Execute write run for one Issue — no Chat; recorded only so the Issue's
    /// transcript is recoverable, scoped further per Issue via the Session row's `issueNumber`.
    case execute
    /// A behind-the-scenes Validate review run for one Persona — no Chat; the forward link lives on the
    /// `review` row's `sessionID`, so the Session itself stays untagged (the Summary is on the row).
    case validate

    /// Whether a Turn of a Session of this kind is **attended** — has a human watching it, so an agent
    /// can put a question to them and wait for the answer. The Chat-backed kinds are; the
    /// behind-the-scenes runs above are not, and a question blocking one of those would wedge it
    /// indefinitely on an answer nobody is there to give.
    ///
    /// Attendedness is a fact about a Turn, not about a kind — this is only what it is resolved from
    /// today, when the surface a Session serves is all there is to go on. Taking over a running Session
    /// in a chat surface will make one of these kinds' Turns attended by answering the question from
    /// something else for that Turn, rather than by changing what the kind means here.
    public var isAttended: Bool {
        switch self {
        case .design, .allocate, .testChat: true
        case .execute, .validate: false
        }
    }
}
