import HerculesApp
import SwiftUI

#if DEBUG
private let isDebugBuild = true
#else
private let isDebugBuild = false
#endif

@main
enum HerculesMain {
    static func main() {
        // Re-exec branch: when launched as the create-issue MCP server, run that stdio loop and exit
        // before any AppKit setup. Returns here only when booting the GUI.
        HerculesEntryPoint.runMCPServerIfRequested()
        HerculesGUI.main()
    }
}

struct HerculesGUI: App {
    @State var model: AppModel

    init() {
        bootstrapHercules()
        self.model = AppModel(
            testChatEnabled: isDebugBuild
        )
    }

    var body: some Scene {
        AppScene(model: model)
    }
}
