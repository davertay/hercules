import SwiftUI

public struct TestChatScene: Scene {
    public var isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public var body: some Scene {
        WindowGroup(for: TestChatWindowData.self) { $data in
            if let data {
                TestChatHost(data: data)
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

/// Owns the per-window ``TestChatModel`` in `@State` so it survives view-graph updates. The model is
/// constructed once, when SwiftUI first builds this host for a given window's ``TestChatWindowData``.
private struct TestChatHost: View {
    @State private var model: TestChatModel

    init(data: TestChatWindowData) {
        _model = State(initialValue: data.toModel())
    }

    var body: some View {
        TestChatView(model: model)
            .navigationTitle(model.windowTitle)
    }
}

extension TestChatWindowData {
    @MainActor
    public func toModel() -> TestChatModel {
        TestChatModel(worktree: worktree)
    }
}
