import Foundation

// The completion gate shared by the writer Phases (Design, PRD): a transactional check that a directed
// Turn actually produced its Artifact via `write_artifact` before the Phase is recorded complete. Snapshot
// the destination file first, run the Turn, then confirm the file now exists, is non-empty, and — over an
// existing file — advanced its modification time.

/// A verifiable footprint of the Artifact file captured before the writer Turn: `nil` when it is absent.
public struct ArtifactSnapshot {
    var modified: Date
    var size: Int
}

public func artifactSnapshot(at url: URL) -> ArtifactSnapshot? {
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let modified = attributes[.modificationDate] as? Date,
        let size = attributes[.size] as? Int
    else { return nil }
    return ArtifactSnapshot(modified: modified, size: size)
}

/// The completion gate: the writer Turn counts only if it produced a non-empty file and — when a file was
/// already there — advanced its modification time. A Turn that never called `write_artifact` leaves the
/// file untouched (or absent), so this returns `false` and the Phase stays incomplete.
public func artifactWasWritten(at url: URL, since before: ArtifactSnapshot?) -> Bool {
    guard let after = artifactSnapshot(at: url), after.size > 0 else { return false }
    if let before, after.modified <= before.modified { return false }
    return true
}
