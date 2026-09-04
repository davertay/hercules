import SwiftUI

/// Per-Workflow settings, presented as a sheet from the toolbar. Built as a `Form` so future settings
/// drop in.
struct WorkflowSettingsView: View {
    let model: WorkflowContainerModel
    @Environment(\.dismiss) private var dismiss

    /// Edited locally and only committed on Done, so Cancel discards. Defaults to the stored title, or the
    /// editable placeholder `New Workflow` for an unnamed Workflow.
    @State private var title: String

    /// Likewise local until Done. Worded as trust rather than as the mechanism it drives: the user is
    /// deciding whether this repository may run shell commands unattended, not picking setting sources.
    @State private var trustsRepositorySettings: Bool

    init(model: WorkflowContainerModel) {
        self.model = model
        let stored = model.rawTitle
        _title = State(initialValue: stored.isEmpty ? "New Workflow" : stored)
        _trustsRepositorySettings = State(initialValue: model.trustsRepositorySettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: $title)

                Toggle(isOn: $trustsRepositorySettings) {
                    Text("Trust this repository's Claude Code settings")
                    Text("Lets the repository's own hooks run shell commands during agent runs.")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    model.updateSettings(title: title, trustsRepositorySettings: trustsRepositorySettings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 360, minHeight: 200)
        .navigationTitle("Workflow Settings")
    }
}
