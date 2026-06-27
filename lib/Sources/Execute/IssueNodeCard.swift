import DAGGraphUI
import IssueGraph
import SwiftUI

struct IssueNodeCard: View {
    let node: DAGNode
    let metrics: DAGGraphMetrics
    let palette: StatusPalette
    let isSelected: Bool
    let activity: NodeActivity?

    var body: some View {
        PulsingNodeView(
            color: palette.color(for: node.status),
            metrics: metrics,
            isPulsing: node.status == .inProgress,
            isSlashed: node.status == .skipped,
            isSelected: isSelected
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(node.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("#\(node.number)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .opacity(0.85)
                }
                .frame(minHeight: 28, alignment: .topLeading)
                if let activity {
                    NodeActivityFooter(activity: activity)
                }
            }
            .foregroundStyle(palette.foregroundColor(for: node.status))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: metrics.nodeWidth, alignment: .leading)
            .frame(minHeight: metrics.nodeMinHeight, alignment: .topLeading)
            .animation(.default, value: activity != nil)
        }
    }
}

#if DEBUG

#Preview("All statuses") {
    @Previewable @State var isSelected = false

    let cases: [(IssueStatus, Int, String, NodeActivity?)] = [
        (.pending, 1, "Recovery branch", nil),
        (.ready, 2, "Conflict path", nil),
        (.inProgress, 3, "First tracer", NodeActivity(steps: 2, tools: 5, elapsed: .seconds(83), isRunning: true)),
        (.done, 4, "Foundations", NodeActivity(steps: 9, tools: 21, elapsed: .seconds(83), cost: 0.04)),
        (.failed, 5, "Wire end-to-end", NodeActivity(steps: 3, tools: 12, elapsed: .seconds(12), cost: 0.01)),
        (.skipped, 6, "Cancelled spike", nil),
        (.proposed, 7, "Don't persist blank rows", nil),
    ]

    return VStack(alignment: .leading, spacing: 16) {
        Button("Toggle Selected") { isSelected.toggle() }
        ForEach(0..<cases.count, id: \.self) { i in
            let (status, number, title, activity) = cases[i]
            HStack(alignment: .top, spacing: 12) {
                Text(String(describing: status))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                IssueNodeCard(
                    node: DAGNode(number: number, title: title, status: status, dependencies: []),
                    metrics: ExecuteView.metrics,
                    palette: .default,
                    isSelected: isSelected,
                    activity: activity
                )
            }
        }
    }
    .padding(24)
}

#Preview("Activity footer states") {
    let states: [(String, IssueStatus, NodeActivity?)] = [
        ("Running", .inProgress, NodeActivity(steps: 2, tools: 5, elapsed: .seconds(83), isRunning: true)),
        ("Done + cost", .done, NodeActivity(steps: 9, tools: 21, elapsed: .seconds(83), cost: 0.04)),
        ("Sub-cent cost", .done, NodeActivity(steps: 4, tools: 6, elapsed: .seconds(7), cost: 0.002)),
        ("Hours", .done, NodeActivity(steps: 40, tools: 120, elapsed: .seconds(3723), cost: 1.5)),
        ("Zero tools", .done, NodeActivity(steps: 1, tools: 0, elapsed: .seconds(4), cost: 0.01)),
        ("No activity", .ready, nil),
    ]

    return VStack(alignment: .leading, spacing: 16) {
        ForEach(0..<states.count, id: \.self) { i in
            let (label, status, activity) = states[i]
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                IssueNodeCard(
                    node: DAGNode(number: i + 1, title: "Wire the executor", status: status, dependencies: []),
                    metrics: ExecuteView.metrics,
                    palette: .default,
                    isSelected: false,
                    activity: activity
                )
            }
        }
    }
    .padding(24)
}

#Preview("Long title wraps") {
    IssueNodeCard(
        node: DAGNode(
            number: 42,
            title: "Migrate legacy workflow registry to typed identifiers across modules",
            status: .inProgress,
            dependencies: []
        ),
        metrics: ExecuteView.metrics,
        palette: .default,
        isSelected: false,
        activity: NodeActivity(steps: 6, tools: 18, elapsed: .seconds(214), isRunning: true)
    )
    .padding(24)
}

#endif
