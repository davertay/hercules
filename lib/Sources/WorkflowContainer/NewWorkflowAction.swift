import AppKit
import IssueReporting
import Store
import SwiftUI

/// Folder-picks a repo, creates the Workflow in `mode`, and opens its window. Shared by the File ▸ New
/// commands and the launch-view buttons — Standard and Small Job each call this with their mode.
@MainActor
public func newWorkflow(openWindow: OpenWindowAction, mode: WorkflowMode = .standard) {
    guard let repo = chooseRepoFolder() else { return }
    withErrorReporting {
        let data = try createWorkflow(repo: repo, mode: mode)
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
