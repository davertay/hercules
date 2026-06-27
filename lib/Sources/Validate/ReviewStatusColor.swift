import Store
import SwiftUI

enum ReviewStatusColor {
    static func color(for status: ReviewStatus?) -> Color {
        switch status {
        case .none: .secondary
        case .running: .orange
        case .reviewed: .indigo
        case .failed: .red
        }
    }
}
