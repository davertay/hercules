import Foundation

public final class TranscriptWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let encoder = JSONEncoder.transcript

    public init(url: URL, append: Bool = false) throws {
        if !append {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: url.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        fh.seekToEndOfFile()
        self.handle = fh
    }

    public func write(_ event: HerculesEvent) throws {
        let data = try encoder.encode(event)
        try writeLine(data)
    }

    public func writeLine(_ data: Data) throws {
        var line = data
        line.append(UInt8(ascii: "\n"))
        handle.write(line)
        handle.synchronizeFile()
    }

    deinit {
        try? handle.close()
    }
}
