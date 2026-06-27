import Foundation
import Store
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
    func standardModeRunsAllFivePhases() {
        #expect(WorkflowMode.standard.phases == [.design, .prd, .allocate, .execute, .validate])
    }

    @Test
    func smallModeRunsThreePhasesSkippingPRDAndAllocate() {
        #expect(WorkflowMode.small.phases == [.design, .execute, .validate])
    }

    @Test
    func predecessorsInSmallModeSkipPRDAndAllocate() {
        #expect(Phase.design.predecessor(in: .small) == nil)
        // PRD and Allocate are absent in Small Job, so Execute is gated directly on Design.
        #expect(Phase.execute.predecessor(in: .small) == .design)
        #expect(Phase.validate.predecessor(in: .small) == .execute)
    }

    @Test
    func predecessorsInStandardModeMatchTheFullChain() {
        #expect(Phase.prd.predecessor(in: .standard) == .design)
        #expect(Phase.allocate.predecessor(in: .standard) == .prd)
        #expect(Phase.execute.predecessor(in: .standard) == .allocate)
        #expect(Phase.validate.predecessor(in: .standard) == .execute)
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
