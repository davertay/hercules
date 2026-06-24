import DAGGraphUI
import IssueGraph
import Store
import SwiftUI

/// The Execute Phase surface: the committed Issues as a live-coloured dependency DAG plus a per-Issue
/// inspector. An invalid graph (cycle/unknown dependency) degrades to a plain Issue list with a banner.
public struct ExecuteView: View {
    let model: ExecuteModel

    public init(model: ExecuteModel) {
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
            } else if model.isEmpty {
                ContentUnavailableView {
                    Label("No Issues yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("The Allocate Phase's committed Issues will appear here as a dependency graph.")
                }
            } else if let message = model.validationMessage {
                InvalidGraphView(message: message, issues: model.issues)
            } else {
                VStack(spacing: 0) {
                    if let failure = model.haltingFailure, !model.isRunning {
                        HaltBanner(issue: failure, reason: model.failureReason(for: failure)) {
                            model.selectNode(failure.number)
                        } onRetry: {
                            model.retry(failure.number)
                        }
                    }
                    HSplitView {
                        DAGGraphView(
                            layoutNodes: model.layoutNodes,
                            nodesByNumber: model.nodesByNumber,
                            metrics: .default,
                            palette: .default,
                            selectedID: model.selectedID,
                            onSelectNode: { model.selectNode($0) }
                        )
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)
                        InspectorPane(
                            issue: model.selectedIssue,
                            failureReason: model.selectedIssue.flatMap { model.failureReason(for: $0) },
                            onRetry: { model.retry($0) },
                            onApprove: { model.approve($0) },
                            onDeny: { model.deny($0) }
                        )
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480, maxHeight: .infinity)
                    }
                    // `HSplitView` proposes only its panes' ideal height; without this the row collapses to
                    // content height and the parent centres it (the inspector's detail ScrollView is the
                    // only thing that stretched it before, so the graph jumped around on selection). Fill.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .navigationTitle("Execute")
        .task { await model.refresh() }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.start()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(!model.canRun)
                .help("Run the Issues sequentially in dependency order")
            }
        }
    }
}

private struct InspectorPane: View {
    let issue: IssueRow?
    let failureReason: String?
    let onRetry: (Int) -> Void
    let onApprove: (Int) -> Void
    let onDeny: (Int) -> Void

    private var isFailed: Bool { issue?.status == IssueRunStatus.failed.rawValue }
    private var isProposed: Bool { issue?.status == "proposed" }

    var body: some View {
        if let issue {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#\(issue.number)")
                            .font(.title3.weight(.semibold).monospaced())
                            .foregroundStyle(.secondary)
                        Text(issue.title)
                            .font(.title3.weight(.semibold))
                    }
                    LabeledContent("Status") { Text(issue.status) }
                        .font(.callout)
                    if !issue.dependencies.isEmpty {
                        LabeledContent("Depends on") {
                            Text(issue.dependencies.map { "#\($0)" }.joined(separator: ", "))
                        }
                        .font(.callout)
                    }
                    if isProposed {
                        ProposalCallout(
                            onApprove: { onApprove(issue.number) },
                            onDeny: { onDeny(issue.number) }
                        )
                    }
                    if isFailed {
                        FailureCallout(reason: failureReason) {
                            onRetry(issue.number)
                        }
                    }
                    if !issue.body.isEmpty {
                        Divider()
                        renderedMarkdown(issue.body)
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
                Label("No Issue selected", systemImage: "sidebar.right")
            } description: {
                Text("Select a node in the graph to see its details.")
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

/// A HITL Proposed Issue's resolution actions, shown inline in the inspector: Approve enters it into the
/// run flow, Deny removes it from the graph. Mirrors the Retry affordance (ADR 0007).
private struct ProposalCallout: View {
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Proposed fix", systemImage: "sparkles")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.purple)
            Text("A Validate Persona proposed this fix. Approve it to run on the next Execute run, or deny it to remove it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Approve", systemImage: "checkmark.circle", action: onApprove)
                    .buttonStyle(.borderedProminent)
                Button("Deny", systemImage: "trash", action: onDeny)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The failure reason for a `failed` Issue plus a Retry action, shown inline in the inspector.
private struct FailureCallout: View {
    let reason: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Run failed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            Text(reason ?? "The run failed for an unknown reason.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onRetry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A halt banner above the graph when a run stopped on a failed Issue: names the Issue, lets the user
/// jump to it, and offers a one-tap retry that resumes the run from there.
private struct HaltBanner: View {
    let issue: IssueRow
    let reason: String?
    let onSelect: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run halted at Issue #\(issue.number) — \(issue.title)")
                    .font(.callout.weight(.semibold))
                if let reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Show", action: onSelect)
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.12))
    }
}

/// Shown when the Issues don't form a valid DAG: a banner over a plain list, so the user can still read
/// the breakdown and fix it in Allocate.
private struct InvalidGraphView: View {
    let message: String
    let issues: [IssueRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.controlBackgroundColor))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("#\(issue.number)")
                                    .font(.callout.weight(.semibold).monospaced())
                                    .foregroundStyle(.secondary)
                                Text(issue.title)
                                    .font(.callout.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            if !issue.dependencies.isEmpty {
                                Text("Depends on \(issue.dependencies.map { "#\($0)" }.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
            }
        }
    }
}
