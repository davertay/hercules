import DAGGraphUI
import IssueGraph
import Store
import SwiftUI

/// The Execute Phase surface: the committed Issues as a live-coloured dependency DAG plus a per-Issue
/// inspector. An invalid graph (cycle/unknown dependency) degrades to a plain Issue list with a banner.
public struct ExecuteView: View {
    let model: ExecuteModel

    static let metrics = DAGGraphMetrics(nodeWidth: 220)

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
                            metrics: Self.metrics,
                            palette: .default,
                            selectedID: model.selectedID,
                            onSelectNode: { model.selectNode($0) }
                        ) { node, isSelected in
                            IssueNodeCard(
                                node: node,
                                metrics: Self.metrics,
                                palette: .default,
                                isSelected: isSelected,
                                activity: model.activity(for: node)
                            )
                        }
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
        .task { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
