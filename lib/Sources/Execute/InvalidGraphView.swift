import Store
import SwiftUI

/// Shown when the Issues don't form a valid DAG: a banner over a plain list, so the user can still read
/// the breakdown and fix it in Allocate.
struct InvalidGraphView: View {
    let message: String
    let issues: [IssueRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.controlBackgroundColor))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("#\(issue.number)")
                                    .font(.callout.weight(.semibold).monospaced())
                                    .foregroundStyle(.secondary)
                                Text(issue.title)
                                    .font(.callout.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            if !issue.dependencies.isEmpty {
                                Text("Depends on \(issue.dependencies.map { "#\($0)" }.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
            }
        }
    }
}
