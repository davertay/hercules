import SwiftUI

/// The app's Settings screen: the Agent executable path and the Extra Arguments forwarded to the
/// harness. Backed by ``SettingsModel``, which loads on appear and persists on every edit.
public struct SettingsView: View {
    @State private var model: SettingsModel

    public init() {
        _model = State(initialValue: SettingsModel())
    }

    /// Injection point for previews and tests.
    init(model: SettingsModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Form {
            Section("Agent Executable") {
                TextField(
                    "Path",
                    text: $model.agentExecutablePath,
                    prompt: Text("~/.local/bin/claude")
                )
                .onSubmit { model.save() }
            }

            Section("Extra Arguments") {
                ForEach($model.arguments) { $row in
                    HStack {
                        TextField("Flag", text: $row.flag, prompt: Text("--flag"))
                            .onSubmit { model.save() }
                        TextField("Value", text: $row.value, prompt: Text("value (optional)"))
                            .onSubmit { model.save() }
                        Button {
                            model.deleteArgument(row)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove argument")
                    }
                }

                Button("Add Argument") {
                    model.addArgument()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { model.load() }
    }
}
