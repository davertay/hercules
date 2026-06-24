import Foundation
import Testing

@testable import Worktree

@Suite("Worktree error messages surface through LocalizedError")
struct ErrorMessageTests {

    @Test("WorktreeError.errorDescription mirrors its description")
    func worktreeErrorDescription() {
        let error = WorktreeError.unsupportedRemote("git@gitlab.com:acme/widgets.git")
        #expect(error.errorDescription == error.description)
    }

    @Test("WorktreeError.rebaseConflict surfaces its message through LocalizedError")
    func rebaseConflictDescription() {
        let error = WorktreeError.rebaseConflict(base: "main")
        #expect(error.errorDescription == error.description)
        #expect(
            error.description
                == "Your branch conflicts with `main`. Resolve the conflicts manually, then open the PR again."
        )
    }
}
