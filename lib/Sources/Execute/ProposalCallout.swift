import SwiftUI

/// A HITL Proposed Issue's resolution actions, shown inline in the inspector: Approve enters it into the
/// run flow, Deny removes it from the graph. Mirrors the Retry affordance (ADR 0007).
struct ProposalCallout: View {
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
