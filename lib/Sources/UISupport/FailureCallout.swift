import SwiftUI

/// A red inspector callout for a failed run: a titled label, the reason, and an optional retry action.
/// Shared by the Execute Issue inspector and the Validate review inspector so the two read identically.
public struct FailureCallout: View {
    let title: String
    let reason: String
    let retry: (() -> Void)?

    public init(title: String, reason: String, retry: (() -> Void)? = nil) {
        self.title = title
        self.reason = reason
        self.retry = retry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button {
                    retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

#if DEBUG

#Preview("With retry") {
    FailureCallout(
        title: "Run failed",
        reason: "The agent produced no commit and made no changes.",
        retry: {}
    )
    .padding()
    .frame(width: 360)
}

#Preview("Without retry") {
    FailureCallout(
        title: "Review failed",
        reason: "Interrupted — the run was stopped or the app quit while this review was running."
    )
    .padding()
    .frame(width: 360)
}

#endif
