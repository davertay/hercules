import SwiftUI

public struct AppLaunchView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Text("Hercules")
    }
}

#Preview {
    AppLaunchView(model: AppModel())
}
