import SwiftUI

public struct NodeActivity: Equatable, Sendable {
    public var steps: Int
    public var tools: Int
    public var elapsed: Duration?
    public var cost: Double?
    public var isRunning: Bool

    public init(
        steps: Int = 0,
        tools: Int = 0,
        elapsed: Duration? = nil,
        cost: Double? = nil,
        isRunning: Bool = false
    ) {
        self.steps = steps
        self.tools = tools
        self.elapsed = elapsed
        self.cost = cost
        self.isRunning = isRunning
    }

    /// Adaptive, no wasted leading zeros: `8s` under a minute, `1:23` for minutes, `1:02:03` past an hour.
    /// Shared by every presentation of the activity (the compact footer and the prominent panel).
    static func formatElapsed(_ elapsed: Duration) -> String {
        let total = max(0, Int(elapsed.components.seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        if minutes > 0 { return String(format: "%d:%02d", minutes, seconds) }
        return "\(seconds)s"
    }

    /// `$0.04`, with a `$0.01` floor so a sub-cent run never reads as the broken-looking `$0.00`.
    static func formatCost(_ cost: Double) -> String {
        String(format: "$%.2f", max(cost, 0.01))
    }
}

public struct NodeActivityFooter: View {
    let activity: NodeActivity

    public init(activity: NodeActivity) {
        self.activity = activity
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let elapsed = activity.elapsed {
                chip("clock", NodeActivity.formatElapsed(elapsed), help: "Elapsed time")
            }
            chip("text.bubble", "\(activity.steps)", help: "Messages and reasoning steps")
            chip("wrench.and.screwdriver", "\(activity.tools)", help: "Tools invoked")
            Spacer()
            if activity.isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else if let cost = activity.cost {
                Text(NodeActivity.formatCost(cost))
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Run cost")
            }
        }
        .font(.caption2.monospaced())
        // Inherit the card's foreground (white on Execute's coloured fills, primary on Validate's cards)
        // and just mute it, rather than forcing `.secondary` — which would wash out on a saturated fill.
        .opacity(0.85)
    }

    private func chip(_ symbol: String, _ value: String, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(value)
                .fixedSize(horizontal: true, vertical: false)
        }
        .help(help)
    }
}

/// A prominent, panel-sized presentation of the same `NodeActivity` the compact `NodeActivityFooter`
/// renders in the DAG cards' footers — for surfaces that hand a single run the whole panel rather than a
/// card corner, like Allocate's big-path PRD checkpoint. Same data (live-ticking elapsed, steps, tools,
/// and cost once the run finalizes), bigger presentation: a large running spinner over a row of stat
/// tiles, so a mechanical multi-step run reads as working and roughly how far along.
public struct NodeActivityPanel: View {
    let activity: NodeActivity

    public init(activity: NodeActivity) {
        self.activity = activity
    }

    public var body: some View {
        VStack(spacing: 20) {
            if activity.isRunning {
                ProgressView()
                    .controlSize(.large)
            }
            HStack(alignment: .top, spacing: 32) {
                if let elapsed = activity.elapsed {
                    stat("clock", NodeActivity.formatElapsed(elapsed), "Elapsed")
                }
                stat("text.bubble", "\(activity.steps)", "Steps")
                stat("wrench.and.screwdriver", "\(activity.tools)", "Tools")
                // Cost lands only once the run finalizes — the model nils it while running, mirroring the
                // footer's rule — so a live panel shows no cost tile.
                if let cost = activity.cost {
                    stat("dollarsign.circle", NodeActivity.formatCost(cost), "Cost")
                }
            }
        }
    }

    private func stat(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
            Text(label)
                .font(.caption.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 64)
    }
}

#if DEBUG

#Preview("Footer states") {
    VStack(alignment: .leading, spacing: 12) {
        NodeActivityFooter(
            activity: NodeActivity(steps: 5, tools: 12, elapsed: .seconds(83), isRunning: true)
        )
        NodeActivityFooter(
            activity: NodeActivity(steps: 190, tools: 221, elapsed: .seconds(3723), cost: 50.04)
        )
        NodeActivityFooter(
            activity: NodeActivity(steps: 1, tools: 0, elapsed: .seconds(4), cost: 0.002)
        )
    }
    .frame(width: 188)
    .padding(16)
}

#Preview("Panel states") {
    VStack(spacing: 32) {
        NodeActivityPanel(
            activity: NodeActivity(steps: 5, tools: 12, elapsed: .seconds(83), isRunning: true)
        )
        Divider()
        NodeActivityPanel(
            activity: NodeActivity(steps: 190, tools: 221, elapsed: .seconds(3723), cost: 0.42)
        )
    }
    .frame(width: 460)
    .padding(32)
}

#endif
