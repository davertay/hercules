import Foundation

struct StderrCollector {
    private var buffer = Data()
    private let cap: Int

    init(cap: Int = 65536) {
        self.cap = cap
    }

    mutating func append(_ bytes: Data) {
        buffer.append(bytes)
        if buffer.count > cap {
            buffer.removeFirst(buffer.count - cap)
        }
    }

    var tail: String {
        String(data: buffer, encoding: .utf8) ?? ""
    }
}
