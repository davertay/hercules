# Agent module — design and implementation spec

This document is the implementation reference for the `Agent` module: a system-level Swift
library that owns the lifecycle of Claude Code CLI subprocesses and exposes a typed, testable
API for talking to them.

Background concepts (Agent, Harness, Session, Turn, Transcript, Worktree, AgentMode, Workflow)
are defined in [`/CONTEXT.md`](../CONTEXT.md). Architectural decisions are recorded in
[`/docs/adr/0001-per-turn-harness-invocation.md`](../docs/adr/0001-per-turn-harness-invocation.md)
and
[`/docs/adr/0002-transcript-format.md`](../docs/adr/0002-transcript-format.md).

---

## 1. Scope

**In scope (MVP):**

- Start a new Session: render Harness arguments, spawn the `claude` subprocess, stream
  stream-json output to a Transcript file, capture the Session ID, return a `Session` value.
- Resume an existing Session for a follow-up Turn: same as above but with `--resume <id>` and
  appending to the existing Transcript.
- Two execution modes: `.readOnly` (strict tool allowlist, worktree mutations impossible) and
  `.write` (full tool access).
- Per-Session data directory with a Transcript JSONL file (passthrough stream-json + Hercules
  framing lines).
- Typed `AgentError` enum surfaced via `throws`; `AgentError.sessionBusy` enforces no
  overlapping Turns on the same Session.
- Cooperative cancellation via `Task.cancel()` → SIGTERM → SIGKILL escalation.
- Pure `Harness.renderArgs(...)` function and configurable binary path for tests; no
  `ProcessLauncher` protocol.
- Snapshot tests for argument rendering; IO tests using a substitutable binary.

**Out of scope (future):**

- Chat UI. The Agent module provides the data (Transcript file + `HerculesEvent` decoder); UI
  is built elsewhere.
- A live-events `AsyncSequence` API. Consumers watch the Transcript file for live updates.
- Multi-vendor abstraction (other CLI agents). The API surface is vendor-neutral by design; the
  Harness-specific rendering layer can be made pluggable later without breaking callers.
- Cloning worktrees, managing Workflows, persisting Session lists across app launches. Those
  are app-level concerns.
- Stream-json decoders for the chat-renderable events (assistant message, tool use, etc.). The
  Agent module is the natural future home for these, but the MVP only ships the framing-line
  decoder.
- Resource caps (max concurrent Harnesses). Will be added at the app layer when needed.

---

## 2. Public API

### 2.1 `AgentClient`

A struct of closures, registered via swift-dependencies as a `@DependencyClient`.

```swift
@DependencyClient
public struct AgentClient: Sendable {
    public var start: @Sendable (StartRequest) async throws(AgentError) -> Session
    public var send: @Sendable (SendRequest) async throws(AgentError) -> Void
}
```

A single `AgentClient` instance serves all Workflows and all concurrent Sessions. It holds no
per-Workflow state. The "live implementation" of this client owns the internal session-busy
lock (see §6.4).

### 2.2 Requests

```swift
public struct StartRequest: Sendable {
    public let prompt: String          // User's prompt, verbatim
    public let worktree: URL           // cwd for the Harness; the git worktree
    public let mode: AgentMode
    public let inputs: InputBundle?    // Optional reference files
    public let storageRoot: URL        // Agent creates <storageRoot>/<session-id>/ under here
}

public struct SendRequest: Sendable {
    public let prompt: String          // User's follow-up prompt
    public let session: Session        // dataDir already resolved
}

public struct InputBundle: Sendable {
    public let root: URL               // Becomes --add-dir argument
    public let relativePaths: [String] // Surfaced to the model in the auto-appended footer
}
```

### 2.3 `Session`

```swift
public struct Session: Codable, Sendable, Hashable, Identifiable {
    public let id: ID
    public let worktree: URL           // Pinned at start
    public let mode: AgentMode         // Pinned at start
    public let dataDir: URL            // <storageRoot>/<session-id>/

    public var transcript: URL { dataDir.appendingPathComponent("transcript.jsonl") }

    public struct ID: Codable, Sendable, Hashable, RawRepresentable {
        public let rawValue: UUID
        public init(rawValue: UUID) { self.rawValue = rawValue }
    }
}
```

Callers persist `Session` values themselves (typically inside their Workflow's storage). The
`Session` is fully self-describing — combined with the `AgentClient`, it's everything needed to
send the next Turn.

### 2.4 `AgentMode`

```swift
public enum AgentMode: String, Codable, Sendable {
    case readOnly   // Strict allowlist: Read, Grep, Glob, WebFetch, WebSearch
    case write      // No tool restrictions
}
```

Pinned on `Session` at start. Cannot change across Turns.

### 2.5 `AgentError`

Typed throws. Eight cases.

```swift
public enum AgentError: Error, Sendable {
    case harnessNotFound(triedPath: URL)
    case harnessFailed(exitCode: Int32, stderrTail: String)
    case harnessCrashed(signal: Int32, stderrTail: String)
    case sessionNotFound(id: Session.ID)                 // --resume failed
    case malformedStream(line: String, underlying: any Error)
    case transcriptIOFailed(URL, underlying: any Error)
    case inputUnreadable(URL, underlying: any Error)
    case dataDirectoryExists(URL)                        // Start collision
    case sessionBusy(id: Session.ID)                     // Overlap on same Session
    case cancelled
}
```

`malformedStream` is **non-fatal**: a single bad line does not abort the Turn. It's recorded
via a `hercules.turn.failed` framing line at end-of-Turn *only if* the Harness process itself
also failed. Otherwise the bad line is logged and parsing continues.

### 2.6 Transcript events

```swift
public enum TranscriptLine: Sendable {
    case hercules(HerculesEvent)
    case harness(rawJSON: Data)        // Opaque stream-json passthrough
}

public enum HerculesEvent: Codable, Sendable {
    case sessionStarted(SessionStarted)
    case turnStarted(TurnStarted)
    case turnEnded(TurnEnded)
    case turnFailed(TurnFailed)

    public struct SessionStarted: Codable, Sendable {
        public let sessionId: Session.ID
        public let worktree: URL
        public let mode: AgentMode
        public let attachedFiles: [String]   // Relative paths from InputBundle
        public let startedAt: Date
    }
    public struct TurnStarted: Codable, Sendable {
        public let userPrompt: String        // The caller's raw prompt
        public let attachedFiles: [String]
        public let startedAt: Date
    }
    public struct TurnEnded: Codable, Sendable {
        public let endedAt: Date
        public let durationMs: Int
    }
    public struct TurnFailed: Codable, Sendable {
        public let endedAt: Date
        public let durationMs: Int
        public let errorKind: String         // String tag matching AgentError case
        public let errorMessage: String      // Human-readable; not load-bearing for logic
    }
}

public func parseTranscriptLine(_ data: Data) throws -> TranscriptLine
```

Encoded JSON for framing lines uses `"type"` discriminator: `"hercules.session.started"`,
`"hercules.turn.started"`, `"hercules.turn.ended"`, `"hercules.turn.failed"`. The
`parseTranscriptLine` function checks for a `"type"` field beginning with `hercules.` and routes
to `HerculesEvent` decoding; otherwise wraps as `.harness(rawJSON:)`.

---

## 3. Harness invocation contract

### 3.1 Argument rendering

A pure function — same one production code uses. No IO, no side effects.

```swift
public enum Harness {
    public static func renderArgs(
        binary: URL,
        operation: Operation,
        worktree: URL,
        mode: AgentMode,
        inputs: InputBundle?,
        sessionId: Session.ID                // We always supply via --session-id
    ) -> [String]

    public enum Operation: Sendable {
        case start
        case resume
    }
}
```

The returned `[String]` flows directly into `Process.arguments`. The binary URL is set
separately on `Process.executableURL`.

### 3.2 Flag set

Every invocation uses:

| Flag | Value | Why |
|---|---|---|
| `--print` | — | Non-interactive mode |
| `--output-format` | `stream-json` | Realtime parseable events on stdout |
| `--input-format` | `text` | Prompt sent via stdin (no arg-size limits) |
| `--session-id <uuid>` | We generate it | Know the Session ID before spawning |
| `--permission-mode` | `bypassPermissions` | UI-less; no prompts can hang us |
| `--setting-sources` | `user,project,local` | Pick up user prefs + project + local overrides |
| `--verbose` | — | Useful stream-json detail |
| `--include-partial-messages` | — | Stream as messages arrive, not just at end of turn |
| `--resume <uuid>` | iff `.resume` | Continue an existing Session |

Mode-specific flags:

| Mode | Flags |
|---|---|
| `.readOnly` | `--allowedTools Read Grep Glob WebFetch WebSearch` |
| `.write` | (none — default tool set) |

Input-bundle-specific flags:

| Condition | Flag |
|---|---|
| `inputs != nil` | `--add-dir <inputs.root>` |

### 3.3 Prompt rendering

The caller's prompt is preserved verbatim. If `inputs` is supplied, a vendor-neutral plain-text
footer is auto-appended listing the relative file paths:

```
{caller's prompt}

Files available (read with your file-read tool):
- relative/path/a.txt
- relative/path/b.md
```

The footer is appended *only* when `inputs` is non-nil and has at least one relative path. The
caller's prompt is never modified beyond that footer.

### 3.4 Process wiring

For each Turn:

1. Resolve `binaryURL` (from configuration; defaults to discovering `claude` on `PATH`).
2. Generate a fresh `UUID` for `start`; reuse `session.id` for `send`.
3. Create the data directory (`<storageRoot>/<session-id>/`). For `start`: if it already exists,
   throw `dataDirectoryExists`. For `send`: it already exists from `start`.
4. Open `transcript.jsonl` in append mode.
5. Write `hercules.session.started` framing line (start only) and `hercules.turn.started`
   framing line. `fsync` after each line.
6. Build args via `Harness.renderArgs(...)`.
7. Construct `Process`:
   - `executableURL = binaryURL`
   - `arguments = renderedArgs`
   - `currentDirectoryURL = worktree`
   - `environment = ProcessInfo.processInfo.environment` (full passthrough)
   - `standardInput = Pipe`
   - `standardOutput = Pipe`
   - `standardError = Pipe`
8. Launch; write the rendered prompt to stdin; close stdin.
9. Drain stdout line by line:
   - Parse each line as JSON to confirm well-formedness; on parse failure, record as
     `malformedStream` (non-fatal) and continue.
   - Write the line verbatim to the Transcript followed by `\n`; `fsync`.
10. Drain stderr into a memory buffer with a 64 KB tail cap (oldest content dropped).
11. `await process.terminationStatus`.
12. Determine outcome:
    - Clean exit (status == 0): write `hercules.turn.ended`; return successfully.
    - Non-zero exit: write `hercules.turn.failed { errorKind: "harnessFailed", ... }`; throw
      `AgentError.harnessFailed(exitCode:, stderrTail:)`.
    - Signal exit: if `weCancelled == true`, write `hercules.turn.failed { errorKind: "cancelled" }`
      and throw `.cancelled`. Otherwise write `errorKind: "harnessCrashed"` and throw
      `.harnessCrashed(signal:, stderrTail:)`.
    - Special-case the Harness's "session not found" failure mode (specific stderr signature or
      stream event during `.resume`) and throw `.sessionNotFound(id:)`.

### 3.5 Cancellation

```swift
try await withTaskCancellationHandler {
    // run process; await stdout drain + termination
} onCancel: {
    weCancelled = true
    process.interrupt()  // SIGINT, then SIGTERM if not gone in flush window
    // separately schedule a SIGKILL after 5s if still alive
}
```

Pseudocode for the escalation:

- On cancellation: set `weCancelled = true`. Send SIGTERM (`process.terminate()`).
- Schedule a 5-second `Task` that, if the process is still running, sends SIGKILL.
- The main loop awaits process exit normally. On exit, the `weCancelled` flag converts whatever
  the exit code says into `AgentError.cancelled`.

---

## 4. On-disk layout

The Agent module owns the contents of `<storageRoot>/<session-id>/`:

```
<storageRoot>/
└── <session-id>/
    └── transcript.jsonl
```

The data directory contains nothing else in the MVP. Future additions (e.g., stderr sidecar,
cache files) will live alongside `transcript.jsonl`.

The Worktree is **outside** the data directory. The Transcript is **outside** the Worktree.

Typical app-level layout (the app's concern, not the Agent's):

```
~/.hercules/workflows/<workflow-id>/
├── config.json                     # app-level
├── worktree/                       # app creates, passes to Agent as `worktree`
└── sessions/                       # app sets storageRoot to this
    ├── <session-1-id>/
    │   └── transcript.jsonl        # Agent writes
    └── <session-2-id>/
        └── transcript.jsonl
```

---

## 5. Concurrency

- **Same-Session overlap:** the live `AgentClient` holds an
  `OSAllocatedUnfairLock<Set<Session.ID>>` of in-flight Session IDs. On entry to `start`/`send`,
  acquire the lock, check membership, throw `AgentError.sessionBusy(id:)` if present, insert
  otherwise. On exit (success or failure), remove via `defer`. About 10 lines of code.
- **Different-Session parallelism:** unbounded in the MVP. Each Turn is a separate process; the
  OS bounds resources naturally. Resource caps can be added at the app layer later.
- **Cancellation:** cooperative via `Task.cancel()`. See §3.5.

---

## 6. Internal architecture

```
AgentClient (public)
  └─ LiveAgentClient (internal — what swift-dependencies wires up)
       ├─ busySessions: OSAllocatedUnfairLock<Set<Session.ID>>
       ├─ binaryURL: URL
       ├─ Harness.renderArgs(...) — pure, also used by snapshot tests
       └─ HarnessRunner — per-Turn process orchestration
             ├─ TranscriptWriter — append-only JSONL with fsync
             ├─ StreamParser — line-buffers stdout, validates JSON shape, dispatches
             ├─ StderrCollector — 64 KB tail buffer
             └─ CancellationHandler — SIGTERM + 5s SIGKILL escalation
```

No `ProcessLauncher` protocol. `HarnessRunner` uses `Foundation.Process` directly; tests
substitute the binary URL.

---

## 7. Testing strategy

### 7.1 Argument-rendering tests (pure)

```swift
@Test func startsFreshSessionWithReadOnlyMode() {
    let args = Harness.renderArgs(
        binary: URL(fileURLWithPath: "/usr/local/bin/claude"),
        operation: .start,
        worktree: URL(fileURLWithPath: "/tmp/wt"),
        mode: .readOnly,
        inputs: nil,
        sessionId: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    )
    assertSnapshot(of: args, as: .customDump)
}
```

One snapshot per scenario: start/resume × readOnly/write × with-inputs/without-inputs (8
combinations). Plus targeted `#expect` assertions for invariants that must never silently
change:

- `args` contains `"--output-format"` followed by `"stream-json"` always.
- `args` contains `"--session-id"` followed by the supplied UUID string always.
- `.readOnly` mode includes `"--allowedTools"`; `.write` mode does not.
- `.resume` mode includes `"--resume"` followed by the session ID; `.start` does not.

### 7.2 IO tests (substituted binary)

Construct `LiveAgentClient` with `binaryURL: URL(fileURLWithPath: "/bin/cat")` (or a tiny
scripted bash fixture). Validates real `Process`/pipe/parse/Transcript-writer code without
launching a real Harness.

Fixtures live in `lib/Tests/AgentTests/Fixtures/`:

- `echo-init.sh` — emits a single stream-json init event then exits.
- `crash.sh` — exits with a non-zero status and stderr.
- `signal-suicide.sh` — kills itself with SIGABRT.
- `malformed.sh` — emits a non-JSON line then a valid one then exits 0.
- `slow.sh` — sleeps long enough to test cancellation/SIGKILL escalation.

Each fixture validates one failure or success path through the real IO/parsing code.

### 7.3 Concurrency tests

- Two simultaneous `send`s on the same Session: second throws `.sessionBusy`.
- Two simultaneous `send`s on different Sessions: both proceed (use a slow fixture so they
  overlap).

### 7.4 Cancellation tests

- Cancel the enclosing Task while the slow fixture is running: error is `.cancelled`, not
  `.harnessCrashed`.
- Cancel a fixture that ignores SIGTERM: SIGKILL fires after 5 s, error still `.cancelled`.

---

## 8. Package layout

```
lib/
├── Package.swift                            # add Agent target + AgentTests target
└── Sources/
    └── Agent/
        ├── AgentClient.swift                # public client struct + live impl
        ├── AgentError.swift                 # public error enum
        ├── AgentMode.swift                  # public mode enum
        ├── Session.swift                    # public Session + ID types
        ├── Requests.swift                   # StartRequest, SendRequest, InputBundle
        ├── Harness.swift                    # renderArgs + Operation
        ├── HarnessRunner.swift              # internal process orchestration
        ├── TranscriptWriter.swift           # internal append/fsync helper
        ├── TranscriptParser.swift           # public parseTranscriptLine
        └── TranscriptEvent.swift            # public TranscriptLine + HerculesEvent
└── Tests/
    └── AgentTests/
        ├── HarnessRenderArgsTests.swift     # snapshot tests
        ├── IOTests.swift                    # binary-substitution tests
        ├── ConcurrencyTests.swift
        ├── CancellationTests.swift
        ├── TranscriptParserTests.swift
        └── Fixtures/
            ├── echo-init.sh
            ├── crash.sh
            ├── signal-suicide.sh
            ├── malformed.sh
            └── slow.sh
```

Add to `Package.swift` targets list in alphabetical order (per `lib/AGENTS.md` convention).
Add `swift-snapshot-testing` and `swift-custom-dump` dependencies if not already on the
package (per `lib/AGENTS.md` they're already listed; just wire them into `AgentTests`).

---

## 9. Recovery and resumption semantics

- **App restart with persisted Session value.** Caller reloads the `Session` (Codable) from
  their own storage. Calls `agent.send(.init(prompt:, session:))`. Agent module spawns the
  Harness with `--resume <session.id>`, appends to the existing Transcript.
- **`start` fails before session ID emission.** Throws (one of the early-failure cases:
  `harnessNotFound`, `inputUnreadable`, etc.). No data directory exists; no Transcript; nothing
  to recover. Caller retries.
- **`start` fails after session ID emission.** Throws `harnessFailed` / `harnessCrashed`. The
  data directory exists and the Transcript contains `hercules.session.started` (audit only) and
  `hercules.turn.failed`. The orphaned partial Session in claude's store is acceptable garbage;
  the caller retries `start` from scratch with a new Session. There is no API-level recovery
  path for this case — it's deliberate (see ADR-0001 reasoning around per-Turn invocation).
- **`send` fails on an existing Session.** Throws an `AgentError`. The Session is unchanged
  from the caller's perspective: prior Turns are preserved. The caller can retry the prompt or
  send a different next prompt.
- **Cancellation.** Throws `.cancelled`. The data directory and Transcript persist. The Session
  is reusable — call `send` again to add a new Turn.

---

## 10. Open implementation questions (defer to implementation)

These are worth flagging but don't need to be resolved before starting:

- **Locating the `claude` binary.** Default to `PATH` resolution via `which claude` or
  `Process.run("/usr/bin/env", ["claude", "--version"])` discovery. Allow override via
  AgentClient configuration. If neither resolves, throw `harnessNotFound`.
- **Detecting `sessionNotFound` precisely.** Empirically determine the Harness's failure
  signature when `--resume <id>` references a missing session. Likely a specific stderr message
  or a stream-json error event. Until determined, treat as `harnessFailed`.
- **stream-json event for partial-message chunks.** With `--include-partial-messages`, partial
  message events appear in the stream. They're written to the Transcript verbatim (passthrough);
  no special handling.
- **Date encoding in framing lines.** Use ISO 8601 with milliseconds via `JSONEncoder` with
  `.iso8601`. Document the encoding in the Codable extension.
- **Test binary path on CI.** `/bin/cat` is universal on macOS. Fixture shell scripts use
  `#!/bin/bash`. Ensure they're marked executable (`chmod +x`) and bundled with the test target
  as resources.

---

## 11. Out-of-scope future enhancements (reference only)

- **`AgentClient.list(storageRoot:)`** — enumerate Sessions in a storage root. Probably an
  app-level helper, not Agent-level.
- **`AgentClient.delete(_:)`** — remove a Session's data directory and ask claude to forget its
  side of the Session. App-level cleanup.
- **Stream-json decoders for assistant messages, tool use, etc.** When the chat UI lands,
  decoders live in the Agent module (the natural home for stream-json typing).
- **Long-lived Harness mode** for latency-sensitive flows. If profiling justifies it, can be
  added behind the same `AgentClient` API.
- **Resource caps** (max concurrent Harnesses). App-layer concern in the MVP; could move into
  the Agent module if it grows arms and legs.
- **Multi-vendor Harness rendering.** The `Harness` enum's `renderArgs` is the natural plugin
  point. Today it produces Claude Code args; tomorrow it could dispatch on a vendor enum.
