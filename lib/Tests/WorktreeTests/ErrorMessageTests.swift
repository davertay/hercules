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
}
