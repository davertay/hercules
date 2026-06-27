import Store

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

    /// The Phase that must complete before this one unlocks *within `mode`'s topology*. In Small Job,
    /// Execute's predecessor is Design (PRD and Allocate are skipped), so the unlock gate keys on Design.
    public func predecessor(in mode: WorkflowMode) -> Phase? {
        let ordered = mode.phases
        guard let index = ordered.firstIndex(of: self), index > 0 else { return nil }
        return ordered[index - 1]
    }
}

extension WorkflowMode {
    /// The ordered Phases this mode runs. `standard` runs all five; `small` (Small Job) runs the
    /// three-Phase Design → Execute → Validate, where the Design Phase grills *and* carves Issues, so
    /// PRD and Allocate are absent. The sidebar and unlock gating derive entirely from this list.
    public var phases: [Phase] {
        switch self {
        case .standard: Phase.allCases
        case .small: [.design, .execute, .validate]
        }
    }
}
