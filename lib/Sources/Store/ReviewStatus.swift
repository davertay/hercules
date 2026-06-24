/// The lifecycle a Validate review run moves through; raw values persist in `ReviewRow.status`. There is
/// no terminal "done" — reviewers hold the latest Summary and stay re-runnable. Idle (never run) is
/// modelled as the absence of a row, not a status value.
public enum ReviewStatus: String, Codable, Sendable, CaseIterable {
    case running
    case reviewed
    case failed
}
