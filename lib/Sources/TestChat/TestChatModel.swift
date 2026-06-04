import Foundation
import Observation

@MainActor
@Observable
public final class TestChatModel {
    public let worktree: URL

    public init(worktree: URL) {
        self.worktree = worktree
    }

    public var windowTitle: String {
        "Test Chat: \(worktree.lastPathComponent)"
    }
}

extension TestChatWindowData {
    @MainActor
    public func toModel() -> TestChatModel {
        TestChatModel(worktree: worktree)
    }
}
