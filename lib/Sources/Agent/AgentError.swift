import Foundation

public enum AgentError: Error, Sendable {
    case harnessNotFound(triedPath: URL)
    case harnessFailed(exitCode: Int32, stderrTail: String)
    case harnessCrashed(signal: Int32, stderrTail: String)
    case harnessIOFailed(underlying: any Error)
    case sessionNotFound(id: Session.ID)
    case malformedStream(line: String, underlying: any Error)
    case transcriptIOFailed(URL, underlying: any Error)
    case inputUnreadable(URL, underlying: any Error)
    case dataDirectoryExists(URL)
    case sessionBusy(id: Session.ID)
    case cancelled
}
