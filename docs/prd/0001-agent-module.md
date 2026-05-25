# PRD 0001 — Agent module

## Problem Statement

Hercules is a macOS agentic workflow app that needs to launch and manage Claude Code CLI processes
on the user's behalf. Today the SPM package has no way to do this: there is no typed Swift API
for starting a Session, sending a follow-up Turn, capturing the session ID, recording a
Transcript, or surfacing errors. Without that foundation, no higher-level feature (chat UI,
Workflow management, multi-Session orchestration) can be built.

The app needs a single, vendor-neutral, testable Swift module that owns the Harness subprocess
lifecycle so callers can think in terms of Sessions and Turns rather than processes, pipes, and
stream-json.

## Solution

A new SPM target, `Agent`, that exposes a small public API for starting and resuming Sessions
against the `claude` CLI. The Agent module:

- Renders Harness arguments via a pure function (deep, snapshot-testable).
- Spawns one `claude` subprocess per Turn (per ADR-0001), with `--print --output-format
  stream-json --input-format text --session-id <uuid> --permission-mode bypassPermissions
  --setting-sources user,project,local --verbose --include-partial-messages`, plus `--resume
  <uuid>` for follow-up Turns and a mode-derived `--allowedTools` allowlist for read-only
  Sessions.
- Streams stdout line-by-line to a Transcript file (`<storageRoot>/<session-id>/transcript.jsonl`)
  containing passthrough stream-json events plus `hercules.*` framing lines (per ADR-0002).
- Surfaces a typed `AgentError` enum via `throws`, including a `sessionBusy` case enforced by an
  internal `OSAllocatedUnfairLock<Set<Session.ID>>`.
- Supports cooperative cancellation via `Task.cancel()` with SIGTERM → 5 s → SIGKILL escalation.

Callers persist `Session` values themselves; the Agent module is stateless across app launches
beyond the on-disk Transcript.

## User Stories

1. As an app developer wiring up a new chat, I want to call `agentClient.start(...)` with a
   prompt, worktree URL, and `AgentMode`, so that I get back a `Session` value I can persist and
   resume later.
2. As an app developer continuing a chat, I want to call `agentClient.send(...)` with a `Session`
   and the next prompt, so that the next Turn is appended to the same Session without me having
   to remember which flags to pass.
3. As an app developer, I want `AgentClient` registered through swift-dependencies, so that I can
   override it in tests via `withDependencies { ... }` without plumbing protocols by hand.
4. As an app developer, I want one `AgentClient` instance to serve all Workflows and all
   concurrent Sessions, so that I don't have to manage per-Workflow client lifecycles.
5. As an app developer in read-only mode, I want the Agent to forbid worktree-mutating tools
   by passing `--allowedTools Read Grep Glob WebFetch WebSearch`, so that a read-only Session
   physically cannot edit files.
6. As an app developer, I want `AgentMode` pinned on the `Session` at start, so that resuming a
   Session cannot accidentally upgrade or downgrade its permissions.
7. As an app developer, I want the Agent to generate the session UUID before spawning the
   Harness and pass it via `--session-id`, so that I know the Session ID without having to parse
   it out of stdout.
8. As an app developer, I want the Agent to create
   `<storageRoot>/<session-id>/transcript.jsonl`, so that all Session state lives in one
   predictable directory that the app can later delete to clean up a Workflow.
9. As an app developer, I want the Transcript directory to live outside the Worktree, so that
   it does not appear in `git status`.
10. As an app developer, I want `Session` to be `Codable`, so that I can serialise it into my
    Workflow's storage and round-trip it across app launches.
11. As an app developer, I want to attach reference files to a Turn by passing an `InputBundle`
    with a `root` URL and `relativePaths`, so that the Harness can read them (via `--add-dir`)
    and the model is told they exist (via an auto-appended footer).
12. As an app developer, I want the prompt-footer auto-append to happen only when at least one
    relative path is supplied, so that prompts without inputs are passed verbatim.
13. As an app developer, I want `AgentError` to be a typed `throws` enum with eight cases, so
    that callers can pattern-match on specific failures (harness not found, harness failed,
    harness crashed, session not found, malformed stream, transcript IO failed, input
    unreadable, data directory exists, session busy, cancelled) rather than `as? NSError`-ing.
14. As an app developer, I want a single malformed stream-json line to be non-fatal — recorded
    via `hercules.turn.failed` only if the Harness itself also fails, otherwise logged and
    parsing continues — so that one transient parse hiccup doesn't abort a working Turn.
15. As an app developer, I want two simultaneous Turns on the same Session to be rejected with
    `AgentError.sessionBusy`, so that I cannot corrupt Session state by accident.
16. As an app developer, I want two simultaneous Turns on different Sessions to both proceed,
    so that I can run multiple chats in parallel without serialisation.
17. As an app developer, I want `Task.cancel()` on the surrounding Task to surface as
    `AgentError.cancelled`, so that cancellation has one canonical failure mode regardless of
    whether the process exited via SIGTERM or SIGKILL.
18. As an app developer, I want SIGKILL to fire 5 seconds after SIGTERM if the Harness hasn't
    exited, so that an unresponsive subprocess cannot wedge the caller indefinitely.
19. As an app developer or tooling author, I want to read a Transcript with `parseTranscriptLine`
    and get back `TranscriptLine.hercules(HerculesEvent)` for framing lines and
    `TranscriptLine.harness(rawJSON:)` for stream-json passthrough, so that I can build a
    Transcript viewer or chat renderer without writing a discriminator by hand.
20. As an app developer, I want the framing-line schema (`hercules.session.started`,
    `hercules.turn.started`, `hercules.turn.ended`, `hercules.turn.failed`) to be a small stable
    vocabulary that the Agent module owns, so that claude's stream-json schema changes don't
    force a coordinated change to the framing format.
21. As an app developer, I want each Transcript line `fsync`'d immediately after write, so that
    a crash mid-Turn leaves a readable file up to the last completed event.
22. As an app developer, I want the framing line's date encoding to be ISO 8601 with
    milliseconds, so that timestamps round-trip predictably across decoders.
23. As an app developer recovering from an app crash, I want to reload my persisted `Session`
    and call `send(...)` again — and have the Agent module just spawn `claude --resume <id>` and
    append to the existing Transcript — so that recovery is the same code path as a normal
    follow-up Turn.
24. As an app developer, I want a failed `start` to throw before creating any session state if
    it fails early (no binary, unreadable input), so that there is nothing to clean up.
25. As an app developer, I want a failed `start` that fails *after* the session ID was emitted to
    leave behind a Transcript containing `hercules.session.started` and `hercules.turn.failed`,
    so that the failure is audit-visible even though the Session itself is unreusable.
26. As an app developer, I want a failed `send` on an existing Session to leave that Session
    intact and resumable, so that I can retry the prompt or send a different next prompt
    without losing prior Turns.
27. As an app developer, I want the Agent module to be vendor-neutral in its public API even
    though it currently only targets Claude Code, so that a future multi-vendor Harness layer can
    be added behind `Harness.renderArgs` without breaking callers.
28. As a contributor extending the module later, I want `Harness.renderArgs` to be a pure
    function with no IO and no side effects, so that the argument-rendering logic is exercised
    identically by production code and snapshot tests.
29. As a contributor, I want the binary path to be configurable on the live `AgentClient`, so
    that tests can substitute `/bin/cat` or a scripted fixture without a `ProcessLauncher`
    protocol.
30. As a contributor, I want fixture shell scripts (`echo-init.sh`, `crash.sh`,
    `signal-suicide.sh`, `malformed.sh`, `slow.sh`) bundled with the test target as executable
    resources, so that real `Process`/pipe/parse code is exercised without launching a real
    Harness.

## Implementation Decisions

### Modules and interfaces

The Agent target is composed of one public client, one internal orchestrator, and several deep
modules that can each be tested in isolation. Per the discussion, `HarnessRunner`'s sub-pieces
(`StreamParser`, `StderrCollector`, `CancellationHandler`) are pulled out as their own
testable units rather than collapsed into the runner.

**Public surface**

- `AgentClient` — a `@DependencyClient` struct of closures: `start(StartRequest)` and
  `send(SendRequest)`. Single instance serves all Workflows and all concurrent Sessions; holds no
  per-Workflow state.
- `Session` — `Codable, Sendable, Hashable, Identifiable` value with `id: Session.ID` (UUID
  wrapper), `worktree: URL`, `mode: AgentMode`, `dataDir: URL`, derived `transcript: URL`.
  Pinned at start; round-trips across app launches.
- `AgentMode` — `enum { readOnly, write }`. Pinned on Session.
- `StartRequest`, `SendRequest`, `InputBundle` — request DTOs as specified in §2.2 of the design.
- `AgentError` — typed throws enum: `harnessNotFound`, `harnessFailed`, `harnessCrashed`,
  `sessionNotFound`, `malformedStream`, `transcriptIOFailed`, `inputUnreadable`,
  `dataDirectoryExists`, `sessionBusy`, `cancelled`.
- `TranscriptLine` — `enum { hercules(HerculesEvent), harness(rawJSON: Data) }`.
- `HerculesEvent` — `enum { sessionStarted, turnStarted, turnEnded, turnFailed }` with the four
  payload structs in §2.6 of the design.
- `parseTranscriptLine(_ data: Data) throws -> TranscriptLine` — pure decoder; routes on
  `"type"` field starting with `hercules.`.

**Deep internal modules** (each testable in isolation):

- `Harness.renderArgs(binary:operation:worktree:mode:inputs:sessionId:) -> [String]` — pure
  function. Same one production and tests use. Operation is `.start` or `.resume`.
- `TranscriptWriter` — append-only JSONL with per-line `fsync`. Hides file handle, encoding,
  durability.
- `StreamParser` — line-buffers stdout, validates JSON well-formedness, dispatches each line as
  either a parsed line or a `malformedStream` event. Pure-ish (takes bytes, emits events).
- `StderrCollector` — 64 KB tail buffer; oldest content dropped when the cap is hit.
- `CancellationHandler` — SIGTERM on cancellation, scheduled SIGKILL after 5 s if the process is
  still alive. Owns the `weCancelled` flag that converts post-exit status into
  `AgentError.cancelled`.

**Internal orchestration**

- `LiveAgentClient` — the live implementation of `AgentClient` registered via
  swift-dependencies. Owns:
  - `busySessions: OSAllocatedUnfairLock<Set<Session.ID>>` for same-Session overlap rejection.
  - `binaryURL: URL` (defaults to `PATH` discovery of `claude`; configurable for tests).
  - Delegates each Turn to `HarnessRunner`.
- `HarnessRunner` — per-Turn process orchestration. Composes `TranscriptWriter`, `StreamParser`,
  `StderrCollector`, `CancellationHandler`. No `ProcessLauncher` protocol; uses
  `Foundation.Process` directly.

### Harness invocation contract

Every Harness invocation passes:

```
--print --output-format stream-json --input-format text
--session-id <uuid> --permission-mode bypassPermissions
--setting-sources user,project,local --verbose --include-partial-messages
[--resume <uuid>]                       iff .resume
[--allowedTools Read Grep Glob WebFetch WebSearch]  iff .readOnly
[--add-dir <inputs.root>]               iff inputs != nil
```

The prompt is written to stdin (no arg-size limits). If `inputs` has at least one relative path,
a footer is auto-appended to the prompt:

```
{caller's prompt}

Files available (read with your file-read tool):
- relative/path/a.txt
- relative/path/b.md
```

Process wiring: `executableURL = binaryURL`; `arguments = renderedArgs`; `currentDirectoryURL =
worktree`; `environment = ProcessInfo.processInfo.environment`; stdin/stdout/stderr piped.

### Turn lifecycle

1. Acquire session-busy lock; throw `sessionBusy` if already in flight.
2. Generate UUID (`.start`) or reuse `session.id` (`.send`).
3. Create `<storageRoot>/<session-id>/` (throw `dataDirectoryExists` on `.start` collision).
4. Open Transcript in append mode.
5. Write `hercules.session.started` (start only) and `hercules.turn.started` framing lines;
   `fsync` after each.
6. Render args, build `Process`, launch.
7. Write rendered prompt to stdin; close stdin.
8. Drain stdout line-by-line through `StreamParser`; bad lines recorded non-fatally.
9. Drain stderr through `StderrCollector` (64 KB tail).
10. Await termination; classify:
    - exit 0 → `hercules.turn.ended` framing line; return.
    - non-zero → `hercules.turn.failed { errorKind: "harnessFailed", ... }`; throw `harnessFailed`.
    - signal + we cancelled → `errorKind: "cancelled"`; throw `cancelled`.
    - signal + we did not cancel → `errorKind: "harnessCrashed"`; throw `harnessCrashed`.
    - special-case the `--resume` "session not found" signature → throw `sessionNotFound`.
11. Release session-busy lock (via `defer`).

### Cancellation

`withTaskCancellationHandler` wraps the run. On cancel: set `weCancelled = true`, send SIGTERM,
schedule a 5 s task that sends SIGKILL if the process is still alive. The main loop awaits exit
normally; `weCancelled` converts whatever the exit code says into `AgentError.cancelled`.

### On-disk layout

```
<storageRoot>/
└── <session-id>/
    └── transcript.jsonl
```

Worktree is outside the data directory. Transcript is outside the Worktree. Nothing else lives
in the data directory in the MVP.

### Concurrency

- Same-Session overlap: rejected with `sessionBusy` via the `OSAllocatedUnfairLock<Set<Session.ID>>`.
- Different-Session parallelism: unbounded in the MVP; OS bounds resources naturally. Resource
  caps are an app-layer concern for later.

### Recovery semantics

- App restart: caller reloads `Session` from their storage; `send(...)` is the resume path.
- `start` fails before session-ID emission: no data directory exists; caller retries.
- `start` fails after session-ID emission: Transcript records the failure; Session is unusable;
  caller retries from scratch with a new Session.
- `send` fails: Session is unchanged; caller retries or moves on.
- Cancellation: data directory and Transcript persist; Session is reusable.

### Package layout

Add an `Agent` target to `lib/Package.swift` (alphabetical order, per `lib/AGENTS.md`):

```
lib/Sources/Agent/
  AgentClient.swift            # public client + live impl
  AgentError.swift
  AgentMode.swift
  Session.swift
  Requests.swift               # StartRequest, SendRequest, InputBundle
  Harness.swift                # renderArgs + Operation
  HarnessRunner.swift          # internal orchestrator
  TranscriptWriter.swift
  StreamParser.swift
  StderrCollector.swift
  CancellationHandler.swift
  TranscriptParser.swift       # public parseTranscriptLine
  TranscriptEvent.swift        # public TranscriptLine + HerculesEvent

lib/Tests/AgentTests/
  HarnessRenderArgsTests.swift
  IOTests.swift
  ConcurrencyTests.swift
  CancellationTests.swift
  TranscriptParserTests.swift
  StreamParserTests.swift
  StderrCollectorTests.swift
  CancellationHandlerTests.swift
  Fixtures/
    echo-init.sh
    crash.sh
    signal-suicide.sh
    malformed.sh
    slow.sh
```

Wire `swift-snapshot-testing` and `swift-custom-dump` into `AgentTests` (they're already listed
in `lib/AGENTS.md`).

## Testing Decisions

### What makes a good test in this module

- Tests assert observable external behavior, not internal call patterns. For pure functions
  (`Harness.renderArgs`, `parseTranscriptLine`), snapshot the output and add targeted
  `#expect` assertions for invariants that must never silently change.
- IO tests substitute the binary path (`binaryURL`) rather than mocking `Process`. The real
  `Foundation.Process`/pipe/parse code runs against scripted fixtures.
- Concurrency and cancellation tests exercise observable error outcomes (which `AgentError` case
  is thrown), not internal flag states.
- Each fixture validates exactly one failure or success path.
- Tests use Swift Testing (`@Test`, `@Suite`), per `lib/AGENTS.md`. Dependencies (Date, UUID) are
  overridden via `withDependencies { ... }` where they appear.

### Modules to test

All four sets requested:

**1. `Harness.renderArgs` — snapshot tests + invariants** (`HarnessRenderArgsTests.swift`).

- Eight scenarios: `{start, resume} × {readOnly, write} × {with inputs, without inputs}` —
  one `assertSnapshot(of: args, as: .customDump)` each.
- Invariant `#expect` assertions:
  - `args` always contains `"--output-format"` followed by `"stream-json"`.
  - `args` always contains `"--session-id"` followed by the supplied UUID string.
  - `.readOnly` always includes `"--allowedTools"`; `.write` never does.
  - `.resume` always includes `"--resume"` followed by the session ID; `.start` never does.
- Prior art: snapshot tests already use `swift-snapshot-testing` and `swift-custom-dump` in this
  package.

**2. `HarnessRunner` IO — substituted binary** (`IOTests.swift`).

Construct `LiveAgentClient` with `binaryURL` pointed at fixture shell scripts. Validates real
`Process`/pipe/`StreamParser`/`TranscriptWriter` interplay end-to-end.

- `echo-init.sh` → emits one stream-json init event then exits → success path, Transcript
  contains the framing lines plus the passthrough event.
- `crash.sh` → non-zero exit with stderr → throws `harnessFailed`; stderr tail captured.
- `signal-suicide.sh` → SIGABRT on itself → throws `harnessCrashed`.
- `malformed.sh` → emits a non-JSON line then a valid one then exits 0 → bad line recorded
  non-fatally; Turn succeeds.
- (`slow.sh` lives here too but is exercised by the cancellation tests.)

Also unit tests for the standalone deep modules:

- `StreamParserTests.swift` — well-formedness checks, framing-vs-passthrough discrimination on
  byte input; assert that malformed lines surface as `malformedStream` events and don't abort.
- `StderrCollectorTests.swift` — 64 KB cap, oldest-content-dropped behavior.
- `TranscriptParserTests.swift` — `parseTranscriptLine` round-trips all four `HerculesEvent`
  cases and yields `.harness(rawJSON:)` for anything else.

**3. Concurrency** (`ConcurrencyTests.swift`).

- Two simultaneous `send`s on the same Session: second throws `.sessionBusy`. Use a slow
  fixture to guarantee overlap.
- Two simultaneous `send`s on different Sessions: both proceed.

**4. Cancellation** (`CancellationTests.swift` + `CancellationHandlerTests.swift`).

- Cancel the enclosing `Task` while `slow.sh` is running → error is `.cancelled`, not
  `.harnessCrashed`.
- Cancel a fixture that ignores SIGTERM → SIGKILL fires after 5 s; error still `.cancelled`.
- Unit-level `CancellationHandlerTests`: `weCancelled` flag flips on cancel; SIGKILL task is
  scheduled with the right delay; signal sending is observable through a substitutable signal
  sink (or via the fixture-driven integration tests if a sink would be over-engineering).

### Prior art

- `lib/Tests/HerculesAppTests/HerculesAppTests.swift` — existing Swift Testing harness in this
  package.
- `swift-snapshot-testing` + `swift-custom-dump` already listed in `lib/AGENTS.md` for use in
  this package.

## Out of Scope

Per §1 of `lib/AgentDesign.md`:

- Chat UI. The Agent module provides the data (Transcript file + decoder); UI is built elsewhere.
- A live-events `AsyncSequence` API. Consumers watch the Transcript file for live updates.
- Multi-vendor Harness abstraction. The API surface is vendor-neutral; `Harness.renderArgs` can
  become pluggable later without breaking callers.
- Worktree management (cloning, `git worktree add`). The app passes a Worktree URL in.
- Workflow management, persistence of Session lists across app launches. App-level concern.
- Stream-json decoders for assistant messages, tool use, partial-message chunks. The Agent
  module is the natural future home; the MVP ships only the framing-line decoder.
- Resource caps (max concurrent Harnesses). App-layer concern in the MVP.
- `AgentClient.list(storageRoot:)` / `AgentClient.delete(_:)`. App-level helpers.
- Long-lived Harness mode (one process per Session). Per ADR-0001, per-Turn invocation is the
  MVP model; long-lived can be added behind the same API later if profiling demands it.

## Further Notes

### Open implementation questions (deferred per §10 of the design)

- **Locating the `claude` binary.** Default to `PATH` resolution; override via `AgentClient`
  configuration. Throw `harnessNotFound` if neither resolves.
- **Detecting `sessionNotFound` precisely.** Empirically determine the Harness's failure
  signature on `--resume <id>` with a missing session (specific stderr message or stream-json
  error event). Until determined, treat as `harnessFailed`.
- **Date encoding in framing lines.** ISO 8601 with milliseconds via `JSONEncoder` `.iso8601`.
  Document the encoding in the Codable extension.
- **Test binary path on CI.** `/bin/cat` is universal on macOS. Fixture scripts use
  `#!/bin/bash`. Ensure `chmod +x` and bundle as test target resources.
- **Partial-message stream events.** With `--include-partial-messages`, these appear in the
  stream; written to the Transcript verbatim (passthrough), no special handling.

### References

- `lib/AgentDesign.md` — full implementation spec.
- `CONTEXT.md` — domain language (Agent, Harness, Session, Turn, Transcript, Worktree, AgentMode,
  Workflow).
- `docs/adr/0001-per-turn-harness-invocation.md` — rationale for one process per Turn.
- `docs/adr/0002-transcript-format.md` — rationale for passthrough stream-json + Hercules
  framing lines.
- `lib/AGENTS.md` — package conventions (Swift Testing, swift-dependencies, alphabetical
  targets, available test libraries).
