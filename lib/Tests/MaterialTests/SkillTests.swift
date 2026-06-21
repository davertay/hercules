import Foundation
import Testing

@testable import Material

@Suite("Skill")
struct SkillTests {

    @Test
    func toIssuesSkillResolvesFromBundle() {
        let skill = loadSkill(.toIssues)
        #expect(skill.name == "to-issues")
        #expect(skill.fileUrl.path.hasSuffix("skills/to-issues/SKILL.md"))
        #expect(skill.folderUrl == skill.fileUrl.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: skill.fileUrl.path))
    }

    @Test
    func implementIssueSkillResolvesFromBundle() {
        let skill = loadSkill(.implementIssue)
        #expect(skill.name == "implement-issue")
        #expect(skill.fileUrl.path.hasSuffix("skills/implement-issue/SKILL.md"))
        #expect(skill.folderUrl == skill.fileUrl.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: skill.fileUrl.path))
    }
}
