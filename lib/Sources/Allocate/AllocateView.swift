import Chat
import DAGGraphUI
import Store
import SwiftUI

/// The Allocate Phase surface. A fork picker chooses how Issues are carved, and the body branches on it:
/// the **big** path proposes from the PRD & Design summary in a fresh Session, the **small** path carves
/// straight from the live grill (its grill turns filtered out). Committed Issues and the composer sit
/// below, and the primary action plus Accept & Write live in the toolbar.
public struct AllocateView: View {
    @Bindable var model: AllocateModel
    @Environment(\.openURL) private var openURL

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
                    bigActions
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

    /// The big-path actions: one button runs the PRD Turn then auto-proposes before any proposal exists;
    /// afterward it splits into the everyday **Re-propose** and the deliberate **Regenerate PRD**. The
    /// written PRD hides behind a low-key **View PRD** disclosure, subordinate to the prominent actions.
    @ViewBuilder
    private var bigActions: some View {
        if model.hasProposed {
            Button("Re-propose", systemImage: "arrow.clockwise") {
                model.propose()
            }
            .disabled(!model.isProposeAvailable)
            Button("Regenerate PRD", systemImage: "doc.badge.gearshape") {
                model.regeneratePRD()
            }
            .disabled(!model.isRegeneratePRDAvailable)
        } else {
            Button("Generate PRD & Propose Issues", systemImage: "list.bullet.rectangle") {
                model.bridgeAndPropose()
            }
            .disabled(!model.isBridgeAvailable)
        }
        if let prdURL = model.prdSavedURL {
            Button("View PRD", systemImage: "doc.text") {
                openURL(prdURL)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.fork {
        case .big:
            if model.isGeneratingPRD {
                PRDProgressView(activity: model.prdActivity)
            } else if model.isIntake {
                BigIntakeActionView(isBridgeAvailable: model.isBridgeAvailable) {
                    model.bridgeAndPropose()
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
    let isBridgeAvailable: Bool
    let bridgeAndPropose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Distil the grill into a PRD, then break it into Issues — grounded in the repo.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Generate PRD & Propose Issues", systemImage: "list.bullet.rectangle") {
                bridgeAndPropose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isBridgeAvailable)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The prominent progress surface shown while the big-path PRD Turn distils the grill into `prd.md`, ahead
/// of the auto-propose that follows — so the mechanical checkpoint reads as working and roughly how far
/// along, not stalled. It renders the live `NodeActivity` through the panel-sized `NodeActivityPanel`
/// (steps, tools, and a live-ticking clock), falling back to a bare spinner until the checkpoint Turn's
/// first rows land.
private struct PRDProgressView: View {
    let activity: NodeActivity?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                Text("Distilling the grill into a PRD…")
                    .font(.title2.weight(.semibold))
                Text("A one-time context reset before Issues are proposed — this runs as a few steps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if let activity {
                NodeActivityPanel(activity: activity)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
