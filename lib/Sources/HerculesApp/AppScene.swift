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

        TestChatScene(isEnabled: model.testChatEnabled)
    }
}
