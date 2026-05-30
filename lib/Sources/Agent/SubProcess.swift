import Foundation

struct SubProcess {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe

    init(executable: URL, arguments: [String], workingDirectory: URL) {
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment

        stdin = Pipe()
        stdout = Pipe()
        stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    var terminationReason: Process.TerminationReason {
        process.terminationReason
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func run() throws {
        try process.run()
    }

    func write(string: String, close: Bool = false) throws {
        try write(string.data(using: .utf8) ?? Data(), close: close)
    }

    func write(_ data: any DataProtocol, close: Bool = false) throws {
        try stdin.fileHandleForWriting.write(contentsOf: data)
        if close {
            try stdin.fileHandleForWriting.close()
        }
    }

    func waitUntilExit() async throws -> (stdOut: Data, stdErr: Data) {
        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading
        return try await withThrowingTaskGroup(of: (Bool, Data?).self) { group in
            var out: Data?
            var err: Data?
            group.addTask { (true, try outHandle.readToEnd()) }
            group.addTask { (false, try errHandle.readToEnd()) }
            for try await (isOut, data) in group {
                if isOut { out = data } else { err = data }
            }
            process.waitUntilExit()
            return (out ?? Data(), err ?? Data())
        }
    }
}
