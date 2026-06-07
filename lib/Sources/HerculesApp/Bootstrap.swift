import Design
import Dependencies
import Foundation

/// Registers app-wide dependencies that can only be resolved from the app target.
/// Call once at launch, before any window is shown.
public func bootstrapHercules() {
    prepareDependencies { _ in
        // add global dependencies here as needed, like shared database or fonts etc
    }
}
