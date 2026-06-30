import SwiftUI

/// Shown when the PRD Phase was completed without producing a PRD. The later Phases work from the Design
/// summary alone; Un-skip reverses the decision, reactivating the Phase so the user can generate a PRD
/// after all (or skip again).
struct PRDSkippedView: View {
    let unskip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chevron.right.2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("PRD skipped")
                .font(.title3.weight(.medium))
            Text("The later Phases will work from the Design summary alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Un-skip", systemImage: "arrow.uturn.backward") {
                unskip()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    PRDSkippedView(unskip: {})
}
