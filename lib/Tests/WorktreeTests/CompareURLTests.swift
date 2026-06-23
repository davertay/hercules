import Foundation
import Testing

@testable import Worktree

@Suite("GitHub compare URL derivation")
struct CompareURLTests {

    @Test("Derives owner/repo from an https origin with a trailing .git")
    func httpsRemote() {
        let url = gitHubCompareURL(
            remote: "https://github.com/acme/widgets.git", base: "main", branch: "feature"
        )
        #expect(url?.absoluteString == "https://github.com/acme/widgets/compare/main...feature?expand=1")
    }

    @Test("Derives owner/repo from an https origin without .git")
    func httpsRemoteNoSuffix() {
        let url = gitHubCompareURL(
            remote: "https://github.com/acme/widgets", base: "develop", branch: "fix"
        )
        #expect(url?.absoluteString == "https://github.com/acme/widgets/compare/develop...fix?expand=1")
    }

    @Test("Derives owner/repo from an ssh shorthand origin")
    func sshRemote() {
        let url = gitHubCompareURL(
            remote: "git@github.com:acme/widgets.git", base: "main", branch: "feature"
        )
        #expect(url?.absoluteString == "https://github.com/acme/widgets/compare/main...feature?expand=1")
    }

    @Test("Derives owner/repo from an ssh:// URL origin")
    func sshSchemeRemote() {
        let url = gitHubCompareURL(
            remote: "ssh://git@github.com/acme/widgets.git", base: "main", branch: "wip"
        )
        #expect(url?.absoluteString == "https://github.com/acme/widgets/compare/main...wip?expand=1")
    }

    @Test("Tolerates surrounding whitespace from git output")
    func trimsWhitespace() {
        let url = gitHubCompareURL(
            remote: "  git@github.com:acme/widgets.git\n", base: "main", branch: "feature"
        )
        #expect(url?.absoluteString == "https://github.com/acme/widgets/compare/main...feature?expand=1")
    }

    @Test("Returns nil for a non-GitHub remote")
    func nonGitHubRemote() {
        #expect(gitHubCompareURL(remote: "git@gitlab.com:acme/widgets.git", base: "main", branch: "x") == nil)
        #expect(gitHubSlug(from: "https://example.com/acme/widgets.git") == nil)
    }

    @Test("Slug extraction strips the .git suffix")
    func slugStripsGitSuffix() {
        #expect(gitHubSlug(from: "git@github.com:acme/widgets.git") == "acme/widgets")
        #expect(gitHubSlug(from: "https://github.com/acme/widgets") == "acme/widgets")
    }
}
