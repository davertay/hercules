import Foundation

public struct HarnessResult: Sendable {
    public let text: String
    public let isError: Bool
}

public func decodeHarnessResult(_ data: Data) -> HarnessResult? {
    guard
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type_ = obj["type"] as? String, type_ == "result",
        let text = obj["result"] as? String
    else { return nil }
    return HarnessResult(text: text, isError: obj["is_error"] as? Bool ?? false)
}
