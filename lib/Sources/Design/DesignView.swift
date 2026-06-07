import SwiftUI

public struct DesignView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label("Design", systemImage: "pencil.and.outline")
        } description: {
            Text("The Design Phase will go here.")
        }
        .navigationTitle("Design")
    }
}

#Preview {
    DesignView()
}
