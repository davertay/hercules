import SwiftUI
import WorkflowContainer

public struct AppLaunchView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Hercules")
                .font(.largeTitle)
            Button("New Workflow") {
                newWorkflow(openWindow: openWindow)
            }
        }
        .padding(40)
    }
}

#Preview {
    AppLaunchView(model: AppModel())
}
