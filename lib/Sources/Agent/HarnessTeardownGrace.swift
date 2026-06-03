import Dependencies
import Foundation

/// How long a Harness is given to exit on `SIGTERM` before it is `SIGKILL`ed
/// when a Turn is cancelled. Injectable so tests can shorten the wait.
private enum HarnessTeardownGraceKey: DependencyKey {
    static let liveValue: Duration = .seconds(5)
    static let testValue: Duration = .milliseconds(200)
}

extension DependencyValues {
    var harnessTeardownGrace: Duration {
        get { self[HarnessTeardownGraceKey.self] }
        set { self[HarnessTeardownGraceKey.self] = newValue }
    }
}
