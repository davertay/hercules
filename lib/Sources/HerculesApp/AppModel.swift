import Observation

@MainActor
@Observable
public final class AppModel {
    public let testChatEnabled: Bool

    public init(let testChatEnabled: Bool = false) {
        self.testChatEnabled = testChatEnabled
    }
}
