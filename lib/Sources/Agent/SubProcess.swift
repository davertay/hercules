import Darwin
import Foundation
import os

struct SubProcess {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe

    // Bridges Foundation's terminationHandler to async/await. The handler may
    // fire before or after a caller starts awaiting, so the lock records both
    // "already terminated" and "someone is waiting" and resolves whichever
    // happens first.
    private struct TerminationBox {
        var terminated = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let terminationLock = OSAllocatedUnfairLock(initialState: TerminationBox())

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

        // Two fixups on the raw pipe descriptors:
        //  - FD_CLOEXEC: Foundation creates pipe fds without it, so a
        //    concurrently-spawned sibling can inherit our pipe write-ends. A
        //    leaked write-end keeps the read side from ever seeing EOF until
        //    that unrelated child exits, serialising parallel work behind the
        //    longest-lived subprocess. Marking them close-on-exec confines each
        //    pipe to its own child; dup2 into the child's stdio (fd 0/1/2)
        //    clears the flag, so the child itself is unaffected.
        //  - F_SETNOSIGPIPE: a harness that exits before reading the prompt
        //    leaves us writing to a reader-less pipe. Without this the write
        //    raises SIGPIPE and kills the whole process; with it the write
        //    fails with EPIPE instead, which `write(_:close:)` handles.
        for pipe in [stdin, stdout, stderr] {
            for fd in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
                let flags = fcntl(fd, F_GETFD)
                if flags != -1 {
                    _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
                }
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            }
        }
    }

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    var terminationReason: Process.TerminationReason {
        process.terminationReason
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func run() throws {
        process.terminationHandler = { [terminationLock] _ in
            let continuation = terminationLock.withLock { box -> CheckedContinuation<Void, Never>? in
                box.terminated = true
                defer { box.continuation = nil }
                return box.continuation
            }
            continuation?.resume()
        }
        try process.run()
    }

    func write(string: String, close: Bool = false) throws {
        try write(string.data(using: .utf8) ?? Data(), close: close)
    }

    func write(_ data: any DataProtocol, close: Bool = false) throws {
        do {
            try stdin.fileHandleForWriting.write(contentsOf: data)
            if close {
                try stdin.fileHandleForWriting.close()
            }
        } catch {
            // A harness that exits before consuming the prompt closes its stdin
            // read-end, so our write fails with EPIPE. That isn't a delivery
            // fault to surface as harnessIOFailed — the child's exit status and
            // stderr are the real signal, so swallow the broken pipe and let
            // waitUntilExit / termination classification report the outcome.
            guard SubProcess.isBrokenPipe(error) else { throw error }
            try? stdin.fileHandleForWriting.close()
        }
    }

    private static func isBrokenPipe(_ error: any Error) -> Bool {
        var nsError = error as NSError
        while true {
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPIPE) {
                return true
            }
            guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else {
                return false
            }
            nsError = underlying
        }
    }

    func waitUntilExit() async throws -> (stdOut: Data, stdErr: Data) {
        // Fully event-driven: drain both pipes via readabilityHandler and learn
        // about exit via terminationHandler. Nothing here blocks a thread, so we
        // neither stall the cooperative concurrency pool nor contend with
        // Foundation's own dispatch machinery for reaping the child (a blocking
        // `Process.waitUntilExit()` on a saturated GCD pool can deadlock forever).
        // Both pipes drain concurrently so a payload larger than the pipe buffer
        // can't wedge the writer.
        async let out = drain(stdout.fileHandleForReading)
        async let err = drain(stderr.fileHandleForReading)
        let (outData, errData) = await (out, err)
        await awaitTermination()
        return (outData, errData)
    }

    /// Accumulates a pipe's output until EOF, driven by the readable dispatch
    /// source rather than a blocking read.
    private func drain(_ handle: FileHandle) async -> Data {
        let buffer = OSAllocatedUnfairLock(initialState: Data())
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                if chunk.isEmpty {
                    fileHandle.readabilityHandler = nil
                    continuation.resume()
                } else {
                    buffer.withLock { $0.append(chunk) }
                }
            }
        }
        return buffer.withLock { $0 }
    }

    /// Suspends until the child has exited and been reaped (terminationStatus
    /// and terminationReason are valid afterwards).
    private func awaitTermination() async {
        await withCheckedContinuation { continuation in
            let alreadyTerminated = terminationLock.withLock { box -> Bool in
                if box.terminated { return true }
                box.continuation = continuation
                return false
            }
            if alreadyTerminated { continuation.resume() }
        }
    }
}
