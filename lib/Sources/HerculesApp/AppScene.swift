import SwiftUI
import TestChat
import WorkflowContainer

public struct AppScene: Scene {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        Window("Hercules", id: "launcher") {
            if let target = PreviewTarget.fromEnvironment() {
                PreviewHarnessEscapeHatch(target: target)
            } else {
                AppLaunchView(model: model)
            }
        }

        WorkflowContainerScene(registry: model.openWorkflows)

        TestChatScene(isEnabled: model.testChatEnabled)

        Settings {
            SettingsView()
        }
    }
}
