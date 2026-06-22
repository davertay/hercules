/// The five stages a Workflow moves through, in order; each consumes the prior Phase's Artifact.
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

    /// The Phase that must complete before this one unlocks. Design consumes the repo, not a Phase, so
    /// it has none and is always unlocked.
    public var predecessor: Phase? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
        return Self.allCases[index - 1]
    }
}
