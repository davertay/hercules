import AppKit
import SwiftUI

public struct TestChatCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Test Chat…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    openWindow(value: url)
                }
            }
        }
    }
}
