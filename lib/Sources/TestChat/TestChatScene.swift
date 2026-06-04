import SwiftUI

public struct TestChatScene: Scene {
    public var isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public var body: some Scene {
        WindowGroup(for: TestChatWindowData.self) { $data in
            if let model = data?.toModel() {
                TestChatView(model: model)
                    .navigationTitle(model.windowTitle)
            }
        }
        .commands {
            if isEnabled {
                TestChatCommands()
            } else {
                EmptyCommands()
            }
        }
    }
}
