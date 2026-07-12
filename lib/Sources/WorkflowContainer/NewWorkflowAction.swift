import AppKit
import IssueReporting
import SwiftUI

/// Folder-picks a repo, creates the Workflow, and opens its window. Shared by the File ▸ New Workflow
/// command and the launch-view button.
@MainActor
public func newWorkflow(openWindow: OpenWindowAction) {
    guard let repo = chooseRepoFolder() else { return }
    withErrorReporting {
        let data = try createWorkflow(repo: repo)
        openWindow(value: data)
    }
}

@MainActor
private func chooseRepoFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose Repository"
    return panel.runModal() == .OK ? panel.url : nil
}
