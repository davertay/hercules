import Foundation
import Testing
import WorkflowContainer

@testable import HerculesApp

@MainActor
@Suite("AppModel open-workflow registry")
struct AppModelRegistryTests {
    @Test func registeringMakesIDOpenAndUnregisteringClosesIt() {
        let model = AppModel()
        let id = UUID()

        #expect(model.openWorkflows.isOpen(id) == false)

        model.openWorkflows.register(id)
        #expect(model.openWorkflows.isOpen(id))

        model.openWorkflows.unregister(id)
        #expect(model.openWorkflows.isOpen(id) == false)
    }

    @Test func tracksDistinctWorkflowsIndependently() {
        let registry = OpenWorkflowRegistry()
        let open = UUID()
        let closed = UUID()

        registry.register(open)

        #expect(registry.isOpen(open))
        #expect(registry.isOpen(closed) == false)
    }
}
