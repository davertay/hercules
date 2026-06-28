import Foundation
import Skills
import Testing

@testable import Validate

@Suite("ReviewPersona")
struct ReviewPersonaTests {
    @Test func codeQualityCarriesItsCatalogText() {
        let persona = ReviewPersona.codeQuality
        #expect(persona.rawValue == "code-quality")
        #expect(persona.title == "Code Quality")
        #expect(!persona.description.isEmpty)
        #expect(persona.skill == .reviewCodeQuality)
    }

    @Test func codeQualityResolvesItsBundledSkill() {
        let resource = ReviewPersona.codeQuality.skillResource
        #expect(resource.name == "review-code-quality")
        #expect(resource.fileUrl.path.hasSuffix("skills/review-code-quality/SKILL.md"))
        #expect(resource.folderUrl == resource.fileUrl.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: resource.fileUrl.path))
    }

    @Test func securityCarriesItsCatalogTextAndSkill() {
        let persona = ReviewPersona.security
        #expect(persona.rawValue == "security")
        #expect(persona.title == "Security")
        #expect(!persona.description.isEmpty)
        #expect(persona.skill == .reviewSecurity)
        #expect(persona.skillResource.name == "review-security")
        #expect(FileManager.default.fileExists(atPath: persona.skillResource.fileUrl.path))
    }

    @Test func catalogContainsBothPersonas() {
        #expect(ReviewPersona.allCases == [.codeQuality, .security])
    }

    @Test func everyPersonaResolvesItsSkillResource() {
        for persona in ReviewPersona.allCases {
            #expect(FileManager.default.fileExists(atPath: persona.skillResource.fileUrl.path))
        }
    }
}
