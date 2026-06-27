import Chat
import Store
import SwiftUI

/// The Small Job first-Phase surface: a grill chat that also carves Issues. Intake shows the prompt;
/// once the conversation starts the Transcript, composer, and committed-Issue list take over, with
/// **Accept & Write Issues** in the toolbar to commit the agreed set.
public struct SmallJobView: View {
    @Bindable var model: SmallJobModel

    public init(model: SmallJobModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isIntake {
                IntakeView()
            } else {
                ChatTranscript(engine: model.engine)
            }
            if !model.issues.isEmpty {
                Divider()
                CommittedIssuesView(issues: model.issues)
            }
            Divider()
            ChatComposer(engine: model.engine)
        }
        .frame(minWidth: 500, minHeight: 400)
        .toolbar {
            if !model.isIntake {
                ToolbarItem(placement: .primaryAction) {
                    Button("Accept & Write Issues", systemImage: "checkmark.circle") {
                        model.acceptAndWrite()
                    }
                    .disabled(!model.isAcceptAvailable)
                }
            }
        }
    }
}

private struct IntakeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("What small job are we doing?")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Grill it out, then write the Issues — they flow straight to Execute.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bounded in height so it doesn't crowd out the Transcript above it. Mirrors Allocate's committed list.
private struct CommittedIssuesView: View {
    let issues: [IssueRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(issues.count) Issue\(issues.count == 1 ? "" : "s") created")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(issues) { issue in
                        IssueRowView(issue: issue)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 220)
        }
    }
}

private struct IssueRowView: View {
    let issue: IssueRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(issue.number)")
                    .font(.callout.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                Text(issue.title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            if !issue.body.isEmpty {
                Text(issue.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !issue.dependencies.isEmpty {
                Text("Depends on \(issue.dependencies.map { "#\($0)" }.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
