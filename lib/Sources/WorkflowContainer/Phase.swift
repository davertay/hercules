/// The five named stages a Workflow moves through, in order. The Workflow window's sidebar lists
/// these; each Phase consumes the prior Phase's Artifact and produces its own.
public enum Phase: String, CaseIterable, Identifiable, Hashable, Sendable {
    case design
    case prd
    case allocate
    case execute
    case validate

    public var id: Self { self }

    public var title: String {
        switch self {
        case .design: "Design"
        case .prd: "PRD"
        case .allocate: "Allocate"
        case .execute: "Execute"
        case .validate: "Validate"
        }
    }

    /// The Phase whose Artifact this Phase consumes — the one that must complete before this Phase
    /// unlocks. The first Phase (Design) consumes the repo, not another Phase's Artifact, so it has
    /// no predecessor and is always unlocked.
    public var predecessor: Phase? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
        return Self.allCases[index - 1]
    }
}
