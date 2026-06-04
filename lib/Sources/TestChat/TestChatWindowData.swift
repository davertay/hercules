import Foundation

public struct TestChatWindowData: Codable,  Hashable {
    public let worktree: URL

    public init(worktree: URL) {
        self.worktree = worktree
    }
}
