import DAGGraphUI
import Store
import SwiftUI

struct PersonaBoard: View {
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
                        activity: model.activity(for: persona),
                        onSelect: { model.selectNode(persona) },
                        onRun: { model.run(persona) }
                    )
                }
            }
            .padding(24)
        }
    }
}

private struct PersonaCard: View {
    let persona: ReviewPersona
    let status: ReviewStatus?
    let isRunning: Bool
    let isSelected: Bool
    let activity: NodeActivity?
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
                Button(action.label, systemImage: action.icon, action: onRun)
                    .controlSize(.small)
                    .disabled(isRunning)
                if let activity {
                    NodeActivityFooter(activity: activity)
                }
            }
            .padding(12)
            .frame(width: 196, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .animation(.default, value: activity != nil)
        }
    }

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

#if DEBUG

private struct PersonaCardState {
    let persona: ReviewPersona
    let status: ReviewStatus?
    var isRunning = false
    var isSelected = false
    let activity: NodeActivity?
}

#Preview("Persona states") {
    let states: [PersonaCardState] = [
        PersonaCardState(persona: .codeQuality, status: nil, activity: nil),
        PersonaCardState(
            persona: .security, status: .running, isRunning: true,
            activity: NodeActivity(steps: 3, tools: 7, elapsed: .seconds(46), isRunning: true)
        ),
        PersonaCardState(
            persona: .codeQuality, status: .reviewed, isSelected: true,
            activity: NodeActivity(steps: 11, tools: 24, elapsed: .seconds(132), cost: 0.06)
        ),
        PersonaCardState(
            persona: .security, status: .failed,
            activity: NodeActivity(steps: 2, tools: 5, elapsed: .seconds(9), cost: 0.01)
        ),
    ]

    return ScrollView {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(0..<states.count, id: \.self) { i in
                let state = states[i]
                PersonaCard(
                    persona: state.persona,
                    status: state.status,
                    isRunning: state.isRunning,
                    isSelected: state.isSelected,
                    activity: state.activity,
                    onSelect: {},
                    onRun: {}
                )
            }
        }
        .padding(24)
    }
    .frame(width: 480, height: 320)
}

#endif

