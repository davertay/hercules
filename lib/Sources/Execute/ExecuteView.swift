import DAGGraphUI
import IssueGraph
import Store
import SwiftUI

/// The Execute Phase surface: renders the Workflow's committed Issues as a live-coloured dependency
/// DAG alongside a per-Issue inspector. Tapping a node selects it and fills the inspector; an invalid
/// dependency graph (cycle or unknown dependency) surfaces a banner and degrades to a plain Issue list
/// rather than a misrendered DAG. Read-only — scheduling and agent runs are later slices.
public struct ExecuteView: View {
    let model: ExecuteModel

    public init(model: ExecuteModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.isEmpty {
                ContentUnavailableView {
                    Label("No Issues yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("The Allocate Phase's committed Issues will appear here as a dependency graph.")
                }
            } else if let message = model.validationMessage {
                InvalidGraphView(message: message, issues: model.issues)
            } else {
                HSplitView {
                    DAGGraphView(
                        layoutNodes: model.layoutNodes,
                        nodesByNumber: model.nodesByNumber,
                        metrics: .default,
                        palette: .default,
                        selectedID: model.selectedID,
                        onSelectNode: { model.selectNode($0) }
                    )
                    .layoutPriority(1)
                    InspectorPane(issue: model.selectedIssue)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .navigationTitle("Execute")
    }
}

/// The per-Issue detail pane: number, title, status, dependencies, and the spec body (already carried
/// on the Issue, so no Agent call). Shows a placeholder prompt until a node is selected.
private struct InspectorPane: View {
    let issue: IssueRow?

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

    /// Renders the spec body as inline markdown, falling back to plain text. Mirrors the rendering used
    /// in the chat transcript; there's no shared repo helper to call.
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

/// Shown when the committed Issues don't form a valid DAG: a banner naming the problem over a plain,
/// non-graph list of the Issues, so the user can still read the breakdown and go fix it in Allocate.
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
