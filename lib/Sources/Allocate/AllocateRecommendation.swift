import Chat
import Foundation

/// Which way Allocate carves Issues, chosen live once the user has seen how the grill went.
public enum AllocateFork: String, Sendable, CaseIterable, Identifiable {
    /// Carve straight from the live grill conversation — no PRD, no document round-trip.
    case small
    /// Propose from the PRD and Design summary in a fresh Session — the document-bridged path.
    case big

    public var id: Self { self }
}

/// The grill's small/big verdict, recovered from the sentinel it appends to its closing message. It rides
/// the message, never `write_artifact` (which stays generic), so dropping the sentinel parse entirely
/// leaves a working Allocate on its static default — the recommendation is a pure convenience layer.
public struct AllocateRecommendation: Equatable, Sendable {
    /// The pre-selected fork: `.big` when the grill recommends distilling a PRD first, `.small` when it
    /// recommends carving straight from the live grill.
    public let fork: AllocateFork
    /// The grill's plain-language verdict and reasoning, the sentinel line stripped — surfaced beside the
    /// two fork choices so the user decides with the rationale in view.
    public let rationale: String

    /// Recovers the grill's recommendation from a `.design` transcript. The grill appends a
    /// `prd_recommended` sentinel to its closing verdict; the carve/propose turns that follow never emit
    /// one, so the last assistant message carrying a sentinel *is* that closing verdict. Returns `nil` when
    /// no message carries the sentinel.
    static func parse(from messages: [Message]) -> AllocateRecommendation? {
        for message in messages.reversed() where message.kind == .assistant {
            guard let prdRecommended = parsePRDRecommended(from: message.text) else { continue }
            return AllocateRecommendation(
                fork: prdRecommended ? .big : .small,
                rationale: rationale(strippingSentinelFrom: message.text)
            )
        }
        return nil
    }

    /// The sentinel: a trivial single-boolean carrier the grill appends to its closing message, e.g.
    /// `<!-- prd_recommended: true -->`. Matched leniently — any surrounding text, `:` or `=`, any casing —
    /// so a lightly reworded closing line still parses; `true` → the PRD/big path, `false` → the small path.
    /// Computed because `Regex` isn't `Sendable`, so a stored static wouldn't be concurrency-safe here
    /// (its old home compiled only by riding the model's `@MainActor` isolation).
    private static var sentinelRegex: Regex<(Substring, Substring)> {
        /prd_recommended\s*[:=]\s*(true|false)/.ignoresCase()
    }

    /// The `prd_recommended` boolean carried by the text, or `nil` when it carries no sentinel.
    static func parsePRDRecommended(from text: String) -> Bool? {
        guard let match = text.firstMatch(of: sentinelRegex) else { return nil }
        return String(match.output.1).lowercased() == "true"
    }

    /// The closing message's prose with the sentinel line removed, for display beside the fork choices.
    private static func rationale(strippingSentinelFrom text: String) -> String {
        text
            .components(separatedBy: "\n")
            .filter { $0.firstMatch(of: sentinelRegex) == nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
