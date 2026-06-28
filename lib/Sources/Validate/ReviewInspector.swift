import Material
import Store
import SwiftUI

struct ReviewInspector: View {
    let persona: ReviewPersona?
    let review: ReviewRow?

    var body: some View {
        if let persona {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(persona.title)
                        .font(.title3.weight(.semibold))
                    let status = review.flatMap { ReviewStatus(rawValue: $0.status) }
                    LabeledContent("Status") { Text(label(for: status)) }
                        .font(.callout)
                    Divider()
                    Text(persona.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if status == .failed, let reason = review?.failureReason {
                        FailureCallout(reason: reason)
                    }
                    if let summary = review?.summary, !summary.isEmpty {
                        Divider()
                        Text("Summary")
                            .font(.callout.weight(.semibold))
                        MarkdownText(summary)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("No Persona selected", systemImage: "sidebar.right")
            } description: {
                Text("Select a Persona to see its review Summary.")
            }
        }
    }
}

private func label(for status: ReviewStatus?) -> String {
    switch status {
    case .none: "Not run"
    case .running: "Reviewing…"
    case .reviewed: "Reviewed"
    case .failed: "Failed"
    }
}
