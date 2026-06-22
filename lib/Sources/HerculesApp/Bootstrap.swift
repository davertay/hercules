import Design
import Dependencies
import Foundation

/// Registers app-wide dependencies. Call once at launch, before any window is shown.
public func bootstrapHercules() {
    prepareDependencies { _ in
    }
}
