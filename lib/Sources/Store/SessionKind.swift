/// The surface a Session serves, persisted so multiple Sessions can share one per-Workflow database
/// without their conversations bleeding into one another (ADR 0005). One Session per (Workflow, kind).
public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case design
    case prd
    case allocate
    case testChat
    /// A behind-the-scenes Execute write run for one Issue — no Chat; recorded only so the Issue's
    /// transcript is recoverable, scoped further per Issue via the Session row's `issueNumber`.
    case execute
}
