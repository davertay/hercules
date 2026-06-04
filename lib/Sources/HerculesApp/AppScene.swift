import SwiftUI
#if DEBUG
import TestChat
#endif

public struct AppScene: Scene {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        #if DEBUG
        WindowGroup {
            AppLaunchView(model: model)
        }
        .commands {
            TestChatCommands()
        }

        WindowGroup(for: URL.self) { $url in
            if let url {
                TestChatView(model: TestChatModel(worktree: url))
            }
        }
        #else
        WindowGroup {
            AppLaunchView(model: model)
        }
        #endif
    }
}
