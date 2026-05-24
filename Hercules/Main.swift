import HerculesApp
import SwiftUI

@main
struct MainApp: App {
    @State var model: AppModel

    init() {
        self.model = AppModel()
    }

    var body: some Scene {
        WindowGroup {
            AppLaunchView(model: model)
        }
    }
}
