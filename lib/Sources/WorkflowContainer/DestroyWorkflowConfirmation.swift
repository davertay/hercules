import SwiftUI

public extension View {
    /// Presents the standard "Destroy this Workflow?" confirmation dialog.
    ///
    /// Use this on any view that needs to confirm a destructive destroy action.
    /// Keeps the title, message, and button labels in one place so both the
    /// launcher row and the in-window toolbar always agree.
    func destroyWorkflowConfirmationDialog(
        isPresented: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Destroy this Workflow?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Destroy Workflow", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently removes the Workflow and destroys any commits that aren't merged elsewhere. This can't be undone."
            )
        }
    }
}
