import Foundation
import Observation

@MainActor
@Observable
public final class TestChatModel {
    public let worktree: URL

    public init(worktree: URL) {
        self.worktree = worktree
    }
}
