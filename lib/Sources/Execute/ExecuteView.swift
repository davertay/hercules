import DAGGraphUI
import IssueGraph
import Store
import SwiftUI
import UISupport

/// The Execute Phase surface: the committed Issues as a live-coloured dependency DAG plus a per-Issue
/// inspector. An invalid graph (cycle/unknown dependency) degrades to a plain Issue list with a banner.
public struct ExecuteView: View {
    let model: ExecuteModel

    static let metrics = DAGGraphMetrics(nodeWidth: 220)

    @State private var graphContentHeight: CGFloat = 0

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
                    MasterDetailSplit(
                        masterIdealWidth: Self.metrics.idealContentWidth(for: model.layoutNodes),
                        masterContentHeight: graphContentHeight
                    ) {
                        DAGGraphView(
                            layoutNodes: model.layoutNodes,
                            nodesByNumber: model.nodesByNumber,
                            metrics: Self.metrics,
                            palette: .default,
                            selectedID: model.selectedID,
                            onSelectNode: { model.selectNode($0) },
                            onContentSizeChange: { graphContentHeight = $0.height }
                        ) { node, isSelected in
                            IssueNodeCard(
                                node: node,
                                metrics: Self.metrics,
                                palette: .default,
                                isSelected: isSelected,
                                activity: model.activity(for: node)
                            )
                        }
                    } detail: {
                        InspectorPane(
                            issue: model.selectedIssue,
                            failureReason: model.selectedIssue.flatMap { model.failureReason(for: $0) },
                            lastTurnAnswer: model.selectedIssue.flatMap { model.lastTurnAnswer(for: $0) },
                            transcriptSession: model.selectedIssue.flatMap { model.transcriptSession(for: $0) },
                            transcriptDatabase: model.transcriptDatabase,
                            onRetry: { model.retry($0) },
                            onApprove: { model.approve($0) },
                            onDeny: { model.deny($0) }
                        )
                    }
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
