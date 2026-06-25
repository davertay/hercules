import SwiftUI

/// A transient bottom-anchored capsule toast. Callers overlay this with `.overlay(alignment: .bottom)`
/// and drive visibility with an `if` guard so the built-in `.transition` fires automatically.
public struct TransientToast: View {
    public let message: String
    public let systemImage: String
    public let tint: Color

    public init(message: String, systemImage: String, tint: Color) {
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
