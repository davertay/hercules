import HerculesApp
import SwiftUI

#if DEBUG
private let isDebugBuild = true
#else
private let isDebugBuild = false
#endif

@main
struct MainApp: App {
    @State var model: AppModel

    init() {
        self.model = AppModel(
            testChatEnabled: isDebugBuild
        )
    }

    var body: some Scene {
        AppScene(model: model)
    }
}
