import SwiftUI
import TestChat

public struct AppScene: Scene {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        WindowGroup {
            AppLaunchView(model: model)
        }
        .commands {
            if model.testChatEnabled {
                TestChatCommands()
            } else {
                EmptyCommands()
            }
        }

        if model.testChatEnabled {
            WindowGroup(for: URL.self) { $url in
                if let url {
                    TestChatView(model: TestChatModel(worktree: url))
                }
            }
        }
    }
}
