import Foundation
import Transcript

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

extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .harnessNotFound(triedPath: let triedPath):
            "Harness not found at \(triedPath.relativePath)"
        case .harnessFailed(exitCode: let exitCode, stderrTail: let stderrTail):
            "Harness failed code=\(exitCode): \(stderrTail)"
        case .harnessCrashed(signal: let signal, stderrTail: let stderrTail):
            "Harness crashed signal=\(signal): \(stderrTail)"
        case .harnessIOFailed(underlying: let underlying):
            "Harness I/O failed caused by: \(underlying.localizedDescription)"
        case .sessionNotFound(id: let id):
            "Session not found \(id)"
        case .malformedStream(line: let line, underlying: let underlying):
            "Malformed stream at '\(line)' caused by: \(underlying.localizedDescription)"
        case .transcriptIOFailed(_, underlying: let underlying):
            "Transcript I/O failed caused by: \(underlying.localizedDescription)"
        case .inputUnreadable(_, underlying: let underlying):
            "Input unreadable caused by: \(underlying.localizedDescription)"
        case .dataDirectoryExists(let url):
            "Data directory already exists at \(url.relativePath)"
        case .sessionBusy(id: let id):
            "Session busy \(id)"
        case .cancelled:
            "Cancelled"
        }
    }
}
