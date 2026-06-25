import SwiftUI

/// Per-Workflow settings, presented as a sheet from the toolbar and auto-presented on first launch so a
/// new Workflow gets named. For now it holds only the title; built as a `Form` so future settings drop in.
struct WorkflowSettingsView: View {
    let model: WorkflowContainerModel
    @Environment(\.dismiss) private var dismiss

    /// Edited locally and only committed on Done, so Cancel discards. Defaults to the stored title, or the
    /// editable placeholder `New Workflow` for an unnamed Workflow.
    @State private var title: String

    init(model: WorkflowContainerModel) {
        self.model = model
        let stored = model.rawTitle
        _title = State(initialValue: stored.isEmpty ? "New Workflow" : stored)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: $title)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    model.updateTitle(title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 360, minHeight: 160)
        .navigationTitle("Workflow Settings")
    }
}
