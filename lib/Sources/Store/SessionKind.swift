/// The surface a Session serves, persisted on the Session row so multiple Sessions can share one
/// per-Workflow database without their conversations bleeding into one another (ADR 0005). One
/// Session per (Workflow, kind).
public enum SessionKind: String, Codable, Sendable, CaseIterable {
    /// The Design Phase's grill-me chat.
    case design
    /// The PRD Phase's to-prd chat.
    case prd
    /// The Allocate Phase's to-issues chat, which proposes Issues and commits them via the MCP
    /// create-issue write tool.
    case allocate
    /// The throwaway developer Test Chat surface.
    case testChat
    /// A behind-the-scenes Execute Phase write run for a single Issue. Unlike the other kinds this
    /// surfaces no Chat; its Session is recorded only so a worked Issue's transcript is recoverable,
    /// linked back to the Issue via the Session row's `issueNumber` (ADR 0005 — one Session per
    /// (Workflow, kind), here scoped further per Issue).
    case execute
}
