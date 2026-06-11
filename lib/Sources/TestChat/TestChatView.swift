import Chat
import SwiftUI

public struct TestChatView: View {
    let model: TestChatModel

    public init(model: TestChatModel) {
        self.model = model
    }

    public var body: some View {
        ChatView(engine: model.engine)
            .frame(minWidth: 500, minHeight: 400)
            .onDisappear {
                model.tearDown()
            }
    }
}
