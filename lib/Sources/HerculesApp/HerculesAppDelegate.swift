import AppKit

#if DEBUG
private let isDebugBuild = true
#else
private let isDebugBuild = false
#endif

/// The app's delegate, and with it the app's lifetime — which is why it also owns the ``AppModel``.
///
/// Quitting has to reach every open Workflow, and `applicationShouldTerminate` is the only place a quit
/// can be got at. A delegate handed its model after the fact would be one that could be asked to shut the
/// app down before it had anything to shut down; owning it means the two can't come apart.
@MainActor
public final class HerculesAppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model, built here rather than in the `App` so the delegate is never without it.
    public let model: AppModel

    override public init() {
        // Before the model, because the model's Phases resolve dependencies as they're built.
        bootstrapHercules()
        model = AppModel(testChatEnabled: isDebugBuild)
        super.init()
    }

    /// Holds the quit open while the open Workflows' agents come down, then lets it through.
    ///
    /// Until a tool could block on a question, quitting orphaned whatever Harnesses were mid-Turn and each
    /// of them ended on its own soon enough: a bounded waste, and nothing worse. A Turn suspended in a
    /// question does not end on its own. Quit with a question on screen and the `claude` process it is
    /// blocked inside outlives the app, holding a conversation nobody can see or answer — so a quit now
    /// has to bring its agents down rather than walk away from them.
    ///
    /// It waits, but only so far: ``OpenWorkflowRegistry/shutDownEverything()`` is bounded, so this defers
    /// termination and can never prevent it. And the ordinary quit, with nothing running, is not deferred
    /// at all — the wait only exists for the case that needs it.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.openWorkflows.hasWorkInFlight else { return .terminateNow }
        Task {
            await model.openWorkflows.shutDownEverything()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
