import Foundation
import Testing

@testable import Skills

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

    /// The `to-prd` Skill content is retained through the topology collapse — the standalone PRD Phase is
    /// gone, but the Skill is reused later by resuming the Design Session.
    @Test
    func toPrdSkillResolvesFromBundle() {
        let skill = loadSkill(.toPrd)
        #expect(skill.name == "to-prd")
        #expect(skill.fileUrl.path.hasSuffix("skills/to-prd/SKILL.md"))
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
