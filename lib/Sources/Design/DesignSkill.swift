import Dependencies
import Foundation

/// The bundled grill-me Skill markdown injected into the Design Phase's Session as an appended
/// system prompt (ADR 0004). The file ships as a resource of the app target, so its URL can only
/// be resolved there; the app registers it via `prepareDependencies` at launch. `nil` means no
/// Skill is injected — the Session still runs, just without the appended prompt.
private enum DesignSkillFileKey: DependencyKey {
    static let liveValue: URL? = nil
    static let testValue: URL? = nil
}

extension DependencyValues {
    public var designSkillFile: URL? {
        get { self[DesignSkillFileKey.self] }
        set { self[DesignSkillFileKey.self] = newValue }
    }
}
