/// The content-block kinds the `StreamProjector` writes into `ContentBlockRow.kind`, re-read by every
/// transcript consumer (chat bubbles, activity tallies). One home for the raw strings so the writer and
/// the switches over them can't drift.
public enum BlockKind: String, Codable, Sendable, CaseIterable {
    case text
    case thinking
    case toolUse = "tool_use"
    /// The user-role echo of a `toolUse` call's output.
    case toolResult = "tool_result"
}

extension ContentBlockRow {
    /// The persisted kind parsed into the vocabulary, or `nil` for an unrecognised stored string.
    public var kindValue: BlockKind? { BlockKind(rawValue: kind) }
}
