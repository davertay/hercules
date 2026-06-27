import DAGGraphUI
import Material
import Store
import SwiftUI

/// The Validate Phase surface: one card per review Persona (built on `PulsingNodeView`) plus a per-Persona
/// inspector, mirroring Execute's master-detail layout. Reviews are started manually and none is required;
/// a card holds the latest Summary and stays re-runnable.
public struct ValidateView: View {
    @Bindable var model: ValidateModel
    @Environment(\.openURL) private var openURL

    public init(model: ValidateModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let message = model.worktreeMessage {
                ContentUnavailableView {
                    Label("Worktree missing", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text(message)
                }
            } else {
                HSplitView {
                    PersonaBoard(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    ReviewInspector(
                        persona: model.selectedPersona,
                        review: model.selectedReview
                    )
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 480, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .task { await model.refresh() }
        .overlay(alignment: .bottom) {
            if let confirmation = model.pullRequestConfirmation {
                TransientToast(message: confirmation, systemImage: "checkmark.circle.fill", tint: .green)
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        model.dismissPullRequestConfirmation()
                    }
            }
        }
        .alert(
            "Couldn't open the pull request",
            isPresented: Binding(
                get: { model.pullRequestError != nil },
                set: { if !$0 { model.pullRequestError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.pullRequestError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        if let url = await model.openPullRequest() {
                            openURL(url)
                        }
                    }
                } label: {
                    if model.isOpeningPullRequest {
                        ProgressView().controlSize(.small)
                        Text("Open Pull Request")
                    } else {
                        Label("Open Pull Request", systemImage: "arrow.triangle.pull")
                    }
                }
                .disabled(!model.canOpenPullRequest)
                .help(
                    model.isOpeningPullRequest
                        ? "Updating branch and pushing…"
                        : "Push the branch and open a GitHub pull request — enabled once every Issue is done"
                )
            }
        }
    }
}
