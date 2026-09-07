import Foundation

/// The channel a Turn's blocking `ask_user` calls travel on: the MCP child announces a call and
/// suspends on it, the app answers it, and the child wakes with that answer and returns it as the
/// tool's result.
///
/// Both ends live in this one type because both are ours, and because neither can be reached through
/// the fixture-harness seam the rest of the Agent's I/O is tested through: those fixtures stand in for
/// the Harness, but the MCP child is a binary the *real* Harness spawns, so under a fixture nothing
/// ever spawns it. One type meeting itself is testable in-process, with no subprocess at all, and
/// cannot drift out of agreement with the other half of the protocol.
///
/// The transport is deliberately unremarkable — a directory of JSON files, polled — and deliberately
/// private to this module. Nothing above `Agent` learns that files, a directory, or a poll interval are
/// involved, which is what leaves the transport replaceable later.
struct QuestionChannel: Sendable {
    /// The channel's whole state, and the only home it gets: a subdirectory of the Turn's scratch area,
    /// created by the first announcement. A pending question is a live process holding an open
    /// request — it cannot outlive the Turn, still less a restart, which is why none of this reaches
    /// the Workflow database.
    let directory: URL

    /// How often each side looks for the other's file. Both waits are bounded by a human's think time,
    /// against which a tenth of a second is nothing.
    var pollInterval: Duration = .milliseconds(100)

    /// A call that has announced itself and is waiting on an answer.
    struct Call: Codable, Equatable, Sendable {
        /// The Harness's own `tool_use.id` for this call, as it arrives in the `tools/call` params'
        /// `_meta` under `claudecode/toolUseId`. It matches the `tool_use.id` in the streamed transcript
        /// exactly, so nothing has to be minted to correlate the two.
        ///
        /// Correlation is per call, rather than per Turn or by position, because the Harness abandons a
        /// tool call without telling the server — no cancellation notification, nothing. Under an
        /// ordinal scheme the answer to an abandoned call would be consumed by whichever call was
        /// waiting next: a wrong answer attributed to the user, which is the worst failure this feature
        /// can produce. Keying on the call forecloses it.
        var callID: String
        var questions: [Question]

        init(callID: String, questions: [Question]) {
            self.callID = callID
            self.questions = questions
        }
    }

    // MARK: - The child's side

    /// Announces `call` and suspends until an answer for that same call arrives.
    ///
    /// There is no timeout. The wait is a human's think time — the Harness's own idle timer is disabled
    /// for exactly that reason — so it ends when the answer lands, or when the task is cancelled.
    func ask(_ call: Call) async throws -> Answer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(call).write(to: announceFile(call.callID), options: .atomic)

        // Retracting the announcement is this call's own job, whether it ends with an answer or with a
        // cancelled wait: one left behind reads as a question still waiting on a user nobody is asking.
        // The announcement goes first and the answer second, so that a `pendingCalls()` running
        // concurrently can never catch an answered call looking pending again.
        defer {
            try? FileManager.default.removeItem(at: announceFile(call.callID))
            try? FileManager.default.removeItem(at: answerFile(call.callID))
        }

        while true {
            if let answer = try answer(for: call.callID) { return answer }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// The answer delivered to `callID`, or `nil` while none has been.
    ///
    /// A delivery whose payload names a different call is left where it is and reported as "not yet":
    /// ignored, never consumed. The file name alone is the weaker half of the correlation — macOS
    /// volumes are case-insensitive by default, so two call ids differing only in case would name one
    /// file — so it is the payload that is trusted.
    private func answer(for callID: String) throws -> Answer? {
        // Absent until the app delivers, which is the state this spends nearly all of its time in.
        guard let data = try? Data(contentsOf: answerFile(callID)) else { return nil }
        let delivery = try JSONDecoder().decode(Delivery.self, from: data)
        guard delivery.callID == callID else { return nil }
        return delivery.answer
    }

    // MARK: - The app's side

    /// Every call that has announced itself and not yet been answered, oldest announcement first.
    func pendingCalls() throws -> [Call] {
        // The directory doesn't exist until the first announcement, which is most Turns.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        var pending: [(announced: Date, call: Call)] = []
        for file in contents where file.lastPathComponent.hasSuffix(Self.announceSuffix) {
            let callID = String(file.lastPathComponent.dropLast(Self.announceSuffix.count))
            // Answered first, announcement second — the mirror of the order `ask` retracts them in, and
            // between them the only ordering that leaves no window where a call it has already consumed
            // still looks pending.
            if FileManager.default.fileExists(atPath: answerFile(callID).path) { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            let call = try JSONDecoder().decode(Call.self, from: data)
            let announced = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate
            pending.append((announced ?? .distantPast, call))
        }
        // The call id breaks ties, so two announcements the filesystem timestamped alike still come back
        // in one order rather than an arbitrary one.
        return pending.sorted { ($0.announced, $0.call.callID) < ($1.announced, $1.call.callID) }.map(\.call)
    }

    /// Suspends until at least one call is pending, then returns every call that is.
    func nextCalls() async throws -> [Call] {
        while true {
            let pending = try pendingCalls()
            if !pending.isEmpty { return pending }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Answers the call `callID` announced. An answer nobody is waiting on is inert: no other call can
    /// pick it up, and it leaves with the rest of the Turn's scratch files.
    func deliver(_ answer: Answer, to callID: String) throws {
        try JSONEncoder().encode(Delivery(callID: callID, answer: answer))
            .write(to: answerFile(callID), options: .atomic)
    }

    // MARK: - The files

    private static let announceSuffix = ".question.json"
    private static let answerSuffix = ".answer.json"

    func announceFile(_ callID: String) -> URL {
        directory.appendingPathComponent(callID + Self.announceSuffix)
    }

    func answerFile(_ callID: String) -> URL {
        directory.appendingPathComponent(callID + Self.answerSuffix)
    }

    /// An answer as it travels: the answer, plus the call it answers.
    private struct Delivery: Codable, Sendable {
        var callID: String
        var answer: Answer
    }
}
