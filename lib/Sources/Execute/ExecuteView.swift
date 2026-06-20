import DAGGraphUI
import SwiftUI

/// The Execute Phase surface: renders the Workflow's committed Issues as a live-coloured dependency
/// DAG. Read-only in this slice — node selection, an inspector pane, and a validation banner land in a
/// follow-up; scheduling and agent runs later still.
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
            } else {
                DAGGraphView(
                    layoutNodes: model.layoutNodes,
                    nodesByNumber: model.nodesByNumber,
                    metrics: .default,
                    palette: .default
                )
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle("Execute")
    }
}
