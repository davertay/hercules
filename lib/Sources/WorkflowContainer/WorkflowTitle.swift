import Foundation

public func workflowWindowDisplayTitle(repoPath: String, title: String) -> String {
    let repoName = repoPath.isEmpty ? "Workflow" : URL(fileURLWithPath: repoPath).lastPathComponent
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? repoName : trimmed
}

public func workflowWindowDisplaySubtitle(repoPath: String, phase: Phase?) -> String {
    let repoName = repoPath.isEmpty ? "Workflow" : URL(fileURLWithPath: repoPath).lastPathComponent
    if let phaseTitle = phase?.title {
        return "\(repoName)::\(phaseTitle)"
    } else {
        return repoName
    }
}

public func workflowListingDisplayTitle(repoPath: String, title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? repoPath : "\(repoPath) - \(trimmed)"
}
