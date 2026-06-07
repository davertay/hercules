import Foundation

public struct SkillResource {
    public let name: String
    public let fileUrl: URL

    public var folderUrl: URL {
        fileUrl.deletingLastPathComponent()
    }

    public init(name: String, fileUrl: URL) {
        self.name = name
        self.fileUrl = fileUrl
    }
}

public func loadSkill(_ skill: Skill) -> SkillResource {
    let url = Bundle.module.url(
        forResource: "SKILL",
        withExtension: "md",
        subdirectory: "Resources/skills/\(skill.rawValue)"
    )
    guard let url else {
        preconditionFailure("Missing skill file '\(skill.rawValue)'")
    }
    return SkillResource(name: skill.rawValue, fileUrl: url)
}
