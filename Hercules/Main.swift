import HerculesApp
import SwiftUI

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
    /// The delegate bootstraps the app and owns its model, because it is also where quitting is caught:
    /// `applicationShouldTerminate` is the only hook that can hold a quit open long enough to bring the
    /// open Workflows' agents down, and it needs the model to do it.
    @NSApplicationDelegateAdaptor(HerculesAppDelegate.self) private var delegate

    var body: some Scene {
        AppScene(model: delegate.model)
    }
}
