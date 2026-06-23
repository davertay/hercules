import DAGGraphUI
import Store
import SwiftUI

/// The Validate Phase surface: one card per review Persona (built on `PulsingNodeView`) plus a per-Persona
/// inspector, mirroring Execute's master-detail layout. Reviews are started manually and none is required;
/// a card holds the latest Summary and stays re-runnable.
public struct ValidateView: View {
    @Bindable var model: ValidateModel
    @Environment(\.openURL) private var openURL

    public init(model: ValidateModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let message = model.worktreeMessage {
                ContentUnavailableView {
                    Label("Worktree missing", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text(message)
                }
            } else {
                HSplitView {
                    PersonaBoard(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    ReviewInspector(
                        persona: model.selectedPersona,
                        review: model.selectedReview
                    )
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 480, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .navigationTitle("Validate")
        .task { await model.refresh() }
        .overlay(alignment: .bottom) {
            if let confirmation = model.pullRequestConfirmation {
                PushedConfirmation(message: confirmation)
                    .task {
                        // Transient — clears itself after a beat.
                        try? await Task.sleep(for: .seconds(4))
                        model.dismissPullRequestConfirmation()
                    }
            }
        }
        .alert(
            "Couldn't open the pull request",
            isPresented: Binding(
                get: { model.pullRequestError != nil },
                set: { if !$0 { model.pullRequestError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.pullRequestError ?? "")
        }
        .toolbar {
            ToolbarItem {
                Button("Open Pull Request", systemImage: "arrow.triangle.pull") {
                    Task {
                        if let url = await model.openPullRequest() {
                            openURL(url)
                        }
                    }
                }
                .disabled(!model.canOpenPullRequest)
                .help("Push the branch and open a GitHub pull request — enabled once every Issue is done")
            }
        }
    }
}

/// The transient "branch pushed" toast shown after a successful PR push.
private struct PushedConfirmation: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The row of Persona cards. Personas have no dependencies on one another, so this is a simple wrapping
/// flow rather than a layered DAG.
private struct PersonaBoard: View {
    let model: ValidateModel

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(ReviewPersona.allCases, id: \.self) { persona in
                    PersonaCard(
                        persona: persona,
                        status: model.status(for: persona),
                        isRunning: model.isRunning(persona),
                        isSelected: model.selectedPersona == persona,
                        onSelect: { model.selectNode(persona) },
                        onRun: { model.run(persona) }
                    )
                }
            }
            .padding(24)
        }
    }
}

/// One Persona's card: status-coloured `PulsingNodeView` with the title, status label, and the in-card
/// action (Run when idle, Re-run when reviewed, Retry when failed).
private struct PersonaCard: View {
    let persona: ReviewPersona
    let status: ReviewStatus?
    let isRunning: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onRun: () -> Void

    var body: some View {
        PulsingNodeView(
            color: ReviewStatusColor.color(for: status),
            metrics: .default,
            isPulsing: isRunning || status == .running,
            isSelected: isSelected
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(persona.title)
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(ReviewStatusColor.label(for: status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action.label, systemImage: action.icon, action: onRun)
                    .controlSize(.small)
                    .disabled(isRunning)
            }
            .padding(12)
            .frame(width: 196, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
        }
    }

    /// The in-card action varies by lifecycle: idle starts a first run, reviewed re-runs, failed retries.
    private var action: (label: String, icon: String) {
        if isRunning { return ("Reviewing…", "hourglass") }
        switch status {
        case .none: return ("Run", "play.fill")
        case .reviewed: return ("Re-run", "arrow.clockwise")
        case .failed: return ("Retry", "arrow.clockwise")
        case .running: return ("Reviewing…", "hourglass")
        }
    }
}

/// The selected Persona's detail: its catalog description, status, and the rendered Summary (or the
/// failure reason). Mirrors Execute's inspector.
private struct ReviewInspector: View {
    let persona: ReviewPersona?
    let review: ReviewRow?

    var body: some View {
        if let persona {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(persona.title)
                        .font(.title3.weight(.semibold))
                    let status = review.flatMap { ReviewStatus(rawValue: $0.status) }
                    LabeledContent("Status") { Text(ReviewStatusColor.label(for: status)) }
                        .font(.callout)
                    Divider()
                    Text(persona.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if status == .failed, let reason = review?.failureReason {
                        FailureCallout(reason: reason)
                    }
                    if let summary = review?.summary, !summary.isEmpty {
                        Divider()
                        Text("Summary")
                            .font(.callout.weight(.semibold))
                        renderedMarkdown(summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("No Persona selected", systemImage: "sidebar.right")
            } description: {
                Text("Select a Persona to see its review Summary.")
            }
        }
    }

    private func renderedMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

private struct FailureCallout: View {
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Review failed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
