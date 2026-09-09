import HerculesApp
import SwiftUI

@main
enum HerculesMain {
    static func main() {
        HerculesEntryPoint.runMCPServerIfRequested()
        HerculesGUI.main()
    }
}

struct HerculesGUI: App {
    @NSApplicationDelegateAdaptor(HerculesAppDelegate.self) private var delegate

    var body: some Scene {
        AppScene(model: delegate.model)
    }
}
