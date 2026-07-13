import Chat
import Store
import SwiftUI

/// The Allocate Phase surface. A fork picker chooses how Issues are carved, and the body branches on it:
/// the **big** path proposes from the PRD & Design summary in a fresh Session, the **small** path carves
/// straight from the live grill (its grill turns filtered out). Committed Issues and the composer sit
/// below, and the primary action plus Accept & Write live in the toolbar.
public struct AllocateView: View {
    @Bindable var model: AllocateModel

    public init(model: AllocateModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForkPicker(fork: $model.fork)
            Divider()
            content
            if !model.issues.isEmpty {
                Divider()
                CommittedIssuesView(issues: model.issues)
            }
            Divider()
            ChatComposer(engine: model.activeEngine)
        }
        .frame(minWidth: 500, minHeight: 400)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.fork == .big {
                    Button("Propose Issues from PRD & Design", systemImage: "list.bullet.rectangle") {
                        model.propose()
                    }
                    .disabled(!model.isProposeAvailable)
                } else {
                    Button("Carve Issues from the grill", systemImage: "scissors") {
                        model.carve()
                    }
                    .disabled(!model.isCarveAvailable)
                }
                Button("Accept & Write Issues", systemImage: "checkmark.circle") {
                    model.acceptAndWrite()
                }
                .disabled(!model.isAcceptAvailable)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.fork {
        case .big:
            if model.isIntake {
                BigIntakeActionView(isProposeAvailable: model.isProposeAvailable) {
                    model.propose()
                }
            } else {
                ChatTranscript(engine: model.engine)
            }
        case .small:
            if model.isSmallIntake {
                SmallIntakeActionView(isCarveAvailable: model.isCarveAvailable) {
                    model.carve()
                }
            } else {
                // The shared `.design` conversation filtered to the carve turns, so the grill is hidden.
                ChatTranscript(engine: model.smallEngine, messages: model.carveMessages)
            }
        }
    }
}

/// Chooses how Allocate carves Issues. A static default for now; a later slice pre-selects it from the
/// grill's recommendation.
private struct ForkPicker: View {
    @Binding var fork: AllocateFork

    var body: some View {
        Picker("How to carve Issues", selection: $fork) {
            Text("Small — carve from the grill").tag(AllocateFork.small)
            Text("Big — from PRD & Design").tag(AllocateFork.big)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct BigIntakeActionView: View {
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

private struct SmallIntakeActionView: View {
    let isCarveAvailable: Bool
    let carve: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Carve Issues straight from the grill you just had — no PRD needed.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Carve Issues from the grill", systemImage: "scissors") {
                carve()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isCarveAvailable)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bounded in height so it doesn't crowd out the Transcript above it.
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
