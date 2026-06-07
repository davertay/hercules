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
}
