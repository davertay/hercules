import Chat
import Store
import SwiftUI

/// The Allocate Phase surface: a hybrid of PRD's directed kickoff and Design's conversation. Intake
/// shows the single Propose action; once a proposal exists the streaming Transcript and a refinement
/// composer take over, with **Propose** and **Accept & Write Issues** reachable from the toolbar.
/// Committed Issues appear below the Transcript with a saved confirmation, derived from the live Issue
/// fetch so they show the moment the commit Turn writes and again on reopening the window.
public struct AllocateView: View {
    @Bindable var model: AllocateModel

    public init(model: AllocateModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isIntake {
                IntakeActionView(isProposeAvailable: model.isProposeAvailable) {
                    model.propose()
                }
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
        .navigationTitle("Allocate")
        .toolbar {
            // Once a proposal exists, keep both actions reachable from the toolbar: Propose re-runs the
            // breakdown (e.g. after a PRD/Design edit), Accept & Write commits the agreed set. Both are
            // disabled while a Turn is in flight.
            if !model.isIntake {
                ToolbarItem {
                    Button("Propose Issues from PRD & Design", systemImage: "list.bullet.rectangle") {
                        model.propose()
                    }
                    .disabled(!model.isProposeAvailable)
                }
                ToolbarItem {
                    Button("Accept & Write Issues", systemImage: "checkmark.circle") {
                        model.acceptAndWrite()
                    }
                    .disabled(!model.isAcceptAvailable)
                }
            }
        }
    }
}

/// The intake state's single action, shown before any proposal conversation exists.
private struct IntakeActionView: View {
    let isProposeAvailable: Bool
    let propose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Break the PRD and Design summary into Issues, grounded in the repo.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Propose Issues from PRD & Design", systemImage: "list.bullet.rectangle") {
                propose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isProposeAvailable)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The committed Issue set: a saved confirmation banner over a scrolling list of each Issue's number,
/// title, body, and dependencies. Bounded in height so it doesn't crowd out the Transcript above it.
private struct CommittedIssuesView: View {
    let issues: [IssueRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(savedConfirmation)
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

    private var savedConfirmation: String {
        "\(issues.count) Issue\(issues.count == 1 ? "" : "s") created"
    }
}

/// One committed Issue: its number and title, the body of spec, and the numbers it depends on.
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
