import SwiftUI

/// A full-width tinted banner across the top of a Phase's content: an icon, a headline, an optional
/// detail line under it, and the caller's buttons on the right. Shared by the Execute Phase's halt and
/// resume banners and the Workflow container's repository-hooks notice so all three keep the same shape.
///
/// Everything that varies between banners is a parameter, including `detailLineLimit` — whether the
/// detail truncates is per-banner, because a detail that's a fixed sentence can wrap freely while one
/// carrying an Issue title or an agent's failure reason has to be capped. `nil` means untruncated.
public struct PhaseBanner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let headline: String
    let detail: String?
    let detailLineLimit: Int?
    let actions: Actions

    public init(
        systemImage: String,
        tint: Color,
        headline: String,
        detail: String? = nil,
        detailLineLimit: Int? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.headline = headline
        self.detail = detail
        self.detailLineLimit = detailLineLimit
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.callout.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(detailLineLimit)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }
}

#if DEBUG

#Preview("Two actions") {
    PhaseBanner(
        systemImage: "exclamationmark.octagon.fill",
        tint: .red,
        headline: "Run halted at Issue #6 — Wire end-to-end",
        detail: "The agent produced no commit and made no changes.",
        detailLineLimit: 2
    ) {
        Button("Show") {}
        Button("Retry") {}
            .buttonStyle(.borderedProminent)
    }
    .frame(width: 640)
    .padding()
}

#Preview("Headline only") {
    PhaseBanner(
        systemImage: "clock.badge.exclamationmark",
        tint: .orange,
        headline: "Session limit reached — resuming automatically at 7:11 PM"
    ) {
        Button("Show") {}
    }
    .frame(width: 640)
    .padding()
}

#endif
