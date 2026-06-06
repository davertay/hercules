### Hercules App Library

App module contains the root level scene. One module per major feature.

### Commands

`swift build` -> build
`swift test` -> test

To run a single test, use `swift test` with a filter:

```bash
swift test --filter MyFeatureTests
swift test --filter "MyFeatureTests/MyTest"
``

### Key libraries

| Library | Purpose |
|---------|---------|
| swift-dependencies | Dependency injection system |
| sqlite-data | Persistence + CloudKit sync |
| swift-structured-queries | Type-safe SQL |
| swift-navigation | State-driven navigation |
| swift-case-paths | Enum key paths for navigation state |
| swift-clocks | Controllable time for tests |
| swift-snapshot-testing | UI snapshot tests |
| swift-custom-dump | Readable diffs in test failures |
| swift-issue-reporting | Runtime warnings for unexpected code paths |

## Key Patterns

**Code Comments**: Inline code comments are rarely needed, only add them if there is some hidden behaviour or additional information that is not obvious by just reading the code instead. Header docs on public APIs are fine of course. 
**Standalone modules**: Feature modules represent single features, like a window that composes other features together, or a rich UI view with a lot of functionality. Infrastructure modules are used by both feature and other infrastructure modules. App module is the top level that holds the Scene and other top level concepts and is imported into the main app and ties everything else together.
**Package.swift**: Targets and dependencies are maintained in alphabetical order.
**Dependency injection via [swift-dependencies](https://github.com/pointfreeco/swift-dependencies)**: Dependencies like Date and UUID generation are injected via `@Dependency`. Override these in tests using `withDependencies { ... }`.
**Testing framework**: Uses Swift Testing (`@Test`, `@Suite` macros), not XCTest

