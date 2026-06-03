import HerculesApp
import SwiftUI
#if DEBUG
import TestChat
#endif

@main
struct MainApp: App {
    @State var model: AppModel

    init() {
        self.model = AppModel()
    }

    var body: some Scene {
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
