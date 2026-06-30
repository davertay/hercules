import SwiftUI

struct IdleActionView: View {
    let isGenerateAvailable: Bool
    let generate: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Turn the Design summary into a PRD grounded in the repo.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Generate PRD from Design Summary", systemImage: "text.document") {
                generate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isGenerateAvailable)
            Spacer()
            HStack {
                Spacer()
                Button("Skip", systemImage: "chevron.right.2") {
                    skip()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isGenerateAvailable)
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview() {
    IdleActionView(isGenerateAvailable: true, generate: {}, skip: {})
}

#Preview("Inactive") {
    IdleActionView(isGenerateAvailable: false, generate: {}, skip: {})
}
