import SwiftUI

public struct TestChatView: View {
    @Bindable var model: TestChatModel

    public init(model: TestChatModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageBubble(message: message)
                        }
                        if model.isRunning {
                            RunningIndicator()
                        }
                        Spacer()
                            .frame(height: 6)
                            .id("bottom")
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: model.isRunning) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }
            Divider()
            Composer(model: model)
        }
        .frame(minWidth: 500, minHeight: 400)
        .onDisappear {
            model.tearDown()
        }
    }

    // These modifiers do not work despite being provided in Apple documentation:
    // .defaultScrollAnchor(.bottom)
    // .defaultScrollAnchor(.top, for: .initialOffset)
    // Instead we scroll to a view id
    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}
