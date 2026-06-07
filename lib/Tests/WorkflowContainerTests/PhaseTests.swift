import Foundation
import Testing

@testable import WorkflowContainer

@Suite("Phase")
struct PhaseTests {
    @Test
    func listsFivePhasesInOrder() {
        #expect(Phase.allCases == [.design, .prd, .allocate, .execute, .validate])
    }

    @Test
    func titles() {
        #expect(Phase.allCases.map(\.title) == ["Design", "PRD", "Allocate", "Execute", "Validate"])
    }

    @Test
    func predecessors() {
        #expect(Phase.design.predecessor == nil)
        #expect(Phase.prd.predecessor == .design)
        #expect(Phase.allocate.predecessor == .prd)
        #expect(Phase.execute.predecessor == .allocate)
        #expect(Phase.validate.predecessor == .execute)
    }

    @Test
    @MainActor
    func modelTitleIsRepoFolderName() {
        let model = WorkflowContainerModel(
            data: WorkflowWindowData(
                id: UUID(0),
                directory: URL(fileURLWithPath: "/tmp/wf"),
                repoPath: "/Users/me/projects/hercules"
            )
        )
        #expect(model.title == "hercules")
    }

    @Test
    @MainActor
    func modelTitleFallsBackWhenRepoPathEmpty() {
        let model = WorkflowContainerModel(
            data: WorkflowWindowData(
                id: UUID(0),
                directory: URL(fileURLWithPath: "/tmp/wf"),
                repoPath: ""
            )
        )
        #expect(model.title == "Workflow")
    }
}
