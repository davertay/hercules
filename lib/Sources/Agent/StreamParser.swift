import Foundation

struct StreamParser {
    enum Line {
        case wellFormed(Data)
        case malformed(raw: String, error: any Error)
    }

    func parse(_ data: Data) -> [Line] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { chunk in
                let chunkData = Data(chunk)
                do {
                    _ = try JSONSerialization.jsonObject(with: chunkData)
                    return .wellFormed(chunkData)
                } catch {
                    let raw = String(data: chunkData, encoding: .utf8) ?? "<non-UTF8 data>"
                    return .malformed(raw: raw, error: error)
                }
            }
    }
}
