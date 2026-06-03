import SwiftUI

public struct TestChatView: View {
    var model: TestChatModel

    public init(model: TestChatModel) {
        self.model = model
    }

    public var body: some View {
        Text(model.worktree.path)
            .padding()
            .frame(minWidth: 400, minHeight: 200)
    }
}
