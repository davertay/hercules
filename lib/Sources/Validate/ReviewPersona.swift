import Skills

/// The compile-time catalog of Validate review Personas — the analogue of `Phase`/`Skill`. Each case is
/// one reviewer the Validate Phase renders as a node; its `rawValue` is the stable `kind` string stored
/// on the `review` row. Adding a Persona is a new case plus a bundled `review-` skill.
public enum ReviewPersona: String, CaseIterable, Sendable {
    case codeQuality = "code-quality"
    case security

    /// The card's heading.
    public var title: String {
        switch self {
        case .codeQuality: "Code Quality"
        case .security: "Security"
        }
    }

    public var description: String {
        switch self {
        case .codeQuality:
            "Reviews the branch for code quality — clarity, naming, structure, duplication, and consistency with the surrounding code."
        case .security:
            "Reviews the branch for security problems — injection, unsafe input handling, secrets in code, path traversal, and risky subprocess or filesystem use."
        }
    }

    public var skill: Skill {
        switch self {
        case .codeQuality: .reviewCodeQuality
        case .security: .reviewSecurity
        }
    }

    public var skillResource: SkillResource {
        loadSkill(skill)
    }
}
