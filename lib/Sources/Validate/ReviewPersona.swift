import Material

/// The compile-time catalog of Validate review Personas — the analogue of `Phase`/`Skill`. Each case is
/// one reviewer the Validate Phase renders as a node; its `rawValue` is the stable `kind` string stored
/// on the `review` row. Adding a Persona is a new case plus a bundled `review-` skill.
public enum ReviewPersona: String, CaseIterable, Sendable {
    case codeQuality = "code-quality"

    /// The card's heading.
    public var title: String {
        switch self {
        case .codeQuality: "Code Quality"
        }
    }

    /// Static catalog text labelling the card and shown in the inspector — there is no per-run headline,
    /// only the captured Summary.
    public var description: String {
        switch self {
        case .codeQuality:
            "Reviews the branch for code quality — clarity, naming, structure, duplication, and consistency with the surrounding code."
        }
    }

    /// The bundled Skill driving this Persona's read-only review run.
    public var skill: Skill {
        switch self {
        case .codeQuality: .reviewCodeQuality
        }
    }

    /// The resolved skill resource (prompt file + its folder), loaded from the Material bundle.
    public var skillResource: SkillResource {
        loadSkill(skill)
    }
}
