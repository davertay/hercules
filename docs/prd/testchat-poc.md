# PRD: TestChat PoC + Transcript module extraction

> Status: draft (not published to the issue tracker). Captures the design agreed in a
> grilling session. Two deliverables, sequenced: **(1)** extract a `Transcript` data
> module from `Agent`; **(2)** build the throwaway `TestChat` PoC on top of it.

## Problem Statement

As the developer building Hercules, I have a real `Agent` module that spawns a `Harness`
per Turn and records a `Transcript`, but **no way to drive it end-to-end through a UI**. I
can't yet feel the prompt → run → result → prompt loop against a live `Harness`, nor
sanity-check the buffered `AgentClient` API and the Transcript-reading path by hand,
before I commit to building the real Workflow/Session UI.

Separately, the `Agent` module currently mixes **two domains** in one place: the
operational concern of wrangling `Harness` subprocesses, and the data concern of the
on-disk event/`Transcript` format. That mixing means the Transcript vocabulary — and any
helpers for decoding `Harness` output — can't be reused cleanly from a UI consumer without
dragging in the whole subprocess module.

## Solution

Two parts, built in order.

**1. Extract a `Transcript` data module** from `Agent` along a clean operational ↔ data
seam. `Transcript` becomes a dependency-light (`Foundation`-only) home for the Transcript
event vocabulary, its reader/writer, the `Session`/`AgentMode` value types serialized into
it, and a **growing catalog of consumer-side decoders for the `Harness`'s stream-json** —
starting with one that extracts the final assistant answer from the terminal `result`
event. `Agent` keeps doing the operational work and continues to *not* decode claude's
stream-json (consistent with ADR 0002); the dependency runs one way, `Agent` → `Transcript`.

**2. Build `TestChat`**, a throwaway, DEBUG-only feature module: a **File-menu** command
opens a window presenting one disposable Workflow as an interactive chat. It runs the real
`Agent` end-to-end in `readOnly` `AgentMode` against a folder the developer picks, displays
each Turn's final assistant answer, accepts the next prompt, and **discards everything when
the window closes**. It exists to evaluate the live machinery by hand; it ships in no
release build and is deliberately untested.

## User Stories

1. As a Hercules developer, I want a "New Test Chat…" command in the **File** menu, so that I can launch the PoC the same way I'd start any new document.
2. As a Hercules developer, I want that command to appear **only in DEBUG builds**, so that the throwaway never reaches a shipping release.
3. As a Hercules developer, I want to pick a folder when I launch a Test Chat, so that the `Harness` runs against a real codebase of my choosing.
4. As a Hercules developer, I want the picked folder to be used directly as the `Worktree`, so that I can exercise the agent against real files without setup.
5. As a Hercules developer, I want the Session pinned to `readOnly` `AgentMode`, so that the agent can read and search but can never mutate my files.
6. As a Hercules developer, I want to type a prompt and run it, so that I can see the real `Harness` respond.
7. As a Hercules developer, I want my prompt to appear immediately in the conversation, so that I get feedback that the Turn has started.
8. As a Hercules developer, I want a clear "working" indicator with the composer disabled while a Turn runs, so that I know the buffered Turn is in flight and can't accidentally submit twice.
9. As a Hercules developer, I want the assistant's final answer rendered when the Turn completes, so that I can read the result of running the agent.
10. As a Hercules developer, I want the answer rendered as markdown where possible, so that it's readable rather than raw text.
11. As a Hercules developer, I want to send a follow-up prompt after the first answer, so that I can hold a multi-Turn conversation on the same Session.
12. As a Hercules developer, I want follow-ups to resume the same Session, so that the conversation has continuity (first prompt starts a Session; later prompts resume it).
13. As a Hercules developer, I want Turn failures shown inline in the conversation, so that I can see when the `Harness` failed, crashed, or produced an error result.
14. As a Hercules developer, I want the Session to remain usable after a failed Turn, so that I can keep trying without relaunching.
15. As a Hercules developer, I want to close the window to end the exploration, so that the disposable Workflow and its `Transcript` are discarded wholesale.
16. As a Hercules developer, I want closing the window to immediately cancel an in-flight Turn and kill the `Harness` subprocess, so that no orphaned process outlives the window.
17. As a Hercules developer, I want the throwaway storage placed in a temp location, so that even a missed cleanup is reclaimed by the OS.
18. As a Hercules developer, I want to open several Test Chat windows at once, so that I can explore different folders side by side, each its own disposable Workflow.
19. As a Hercules developer, I want `TestChat` to use the real `AgentClient` with no special wiring, so that what I observe matches production behavior.
20. As a Hercules developer, I want a reusable `Transcript` module that owns the event vocabulary and decoders, so that the real app's UI can later read Transcripts without depending on the subprocess machinery.
21. As a Hercules developer, I want the harness stream-json decoder to extract the final answer from the `result` event and flag error results, so that consumers get the assistant's reply with one simple call.
22. As a Hercules developer, I want the `Transcript` decoders unit-tested in isolation, so that the reusable production code is trustworthy as the catalog grows.
23. As a Hercules developer, I want the `Agent` operational behavior unchanged by the extraction, so that the refactor is safe and observable only as a module boundary move.
24. As a Hercules developer, I want `TestChat` left untested, so that I don't ossify code I intend to throw away — the PoC itself is the test.

## Implementation Decisions

**Sequencing**
- Land the `Transcript` extraction as its own production PR (gated by CI — no local build/test per AGENTS.md), then build `TestChat` on top. Avoids building a throwaway decoder that would later have to migrate into `Transcript`.

**`Transcript` module (production)**
- New module, `Foundation`-only — no dependency on `Subprocess` or `swift-dependencies`. Dependency direction is one-way: operational `Agent` → data `Transcript`.
- Moves into `Transcript`: the Transcript event model (`TranscriptLine` / `HerculesEvent` and its four framing types), the line reader (`parseTranscriptLine` + JSON coders), the `Transcript` writer, and the `Session` / `Session.ID` / `AgentMode` value types serialized into the Transcript.
- The writer's visibility is widened to `public` because operational code remaining in `Agent` (the runner, the termination classifier) still writes Transcript events.
- `StreamParser` **stays in `Agent`**: it is format-agnostic NDJSON ingestion of live `Harness` stdout with no Transcript-format knowledge, used only at ingestion time. Placement principle: *"knows the Transcript/event format" → `Transcript`; "process/ingestion mechanics" → `Agent`.*
- New in `Transcript`: a consumer-side decoder for the `Harness` stream-json that reads the terminal `result` event and yields the final answer text plus an error flag. This is the first entry in a catalog that may grow (assistant text blocks, tool-use) later. `Agent` continues to write claude's stream-json through verbatim and never decodes it (preserves ADR 0002).
- `AgentClient.start` / `send` continue to return `Session`, which now lives in `Transcript`; callers therefore import both modules. No re-export shimming.
- Package targets and dependencies remain alphabetised (per lib/AGENTS.md).

**`TestChat` module (throwaway, DEBUG-only)**
- A top-level user-facing feature module depending on `Agent` (to run, via the injected `AgentClient`) and `Transcript` (to decode). Only the App layer wires it; it imports no other feature module.
- Public entry is a SwiftUI view plus an `@Observable` model that takes a `worktree: URL`, creates and owns a temp `storageRoot`, and resolves the live `AgentClient` through dependency injection (no explicit App-side registration needed).
- Turn lifecycle: the model holds an optional `Session`. The first submit calls `start` (creates the Session, runs Turn 1); subsequent submits call `send` to resume. Submitting optimistically appends the user prompt, sets a running flag (composer disabled, spinner), runs the Turn in a `Task`, and on completion re-reads and re-parses the entire `Transcript`.
- Because the `AgentClient` API is **buffered** (a call returns only after the whole Turn completes; output lands in the Transcript file), display is reconstructed by re-parsing after each Turn rather than streamed.
- Read orchestration lives in `TestChat`: walk the Transcript line by line via the `Transcript` reader; for each Turn, pair the `hercules.turn.started` prompt with that Turn's single `result` answer (decoded via the `Transcript` decoder); render `hercules.turn.failed` as an error entry. (One `result` per Turn, since each Turn is one `Harness` invocation — ADR 0001.)
- Display depth is **final-answer-only**: user bubble + assistant bubble, markdown via attributed string with a plain/raw fallback. Intermediate tool activity is intentionally hidden in v1.
- `AgentMode` is `readOnly`; the `Harness` runs directly in the picked folder (no git worktree required, since `readOnly` cannot mutate). The throwaway promise reduces to deleting the temp `storageRoot`.
- **No cancel button in v1.** A Turn runs to completion; the composer is disabled meanwhile.
- Windowing uses a value-driven window group keyed on the folder `URL`; the File-menu command opens a window with the chosen URL. Multiple concurrent windows are allowed, each its own disposable Workflow.
- The File-menu command is added to the New section of the File menu and is wrapped in a `#if DEBUG` compile guard, along with its wiring.
- Folder selection is **not** part of `TestChat`. For the PoC the App-level menu action runs a throwaway inline open-panel and passes the resulting `URL` into the window. The reusable production picker is out of scope (home TBD).
- Teardown: on window close, the root view's disappearance triggers a `tearDown()` that cancels the in-flight `Task` (swift-subprocess escalates SIGTERM → grace → SIGKILL to the `Harness`) and best-effort removes the temp `storageRoot`; the model's deinit is a backstop. The earlier-noted cancellation asymmetry in the resume path is irrelevant here because the Workflow is being discarded.

## Testing Decisions

- A good test asserts **external behavior through the module's interface**, not implementation details — same posture as the existing `Agent` tests (Swift Testing `@Test`/`@Suite`, `withDependencies` for injected values, snapshot tests where output shape matters).
- **`Transcript` is tested.** The new `Harness` stream-json decoder gets unit tests: a successful `result` event yields the answer text; an error result is flagged; a missing `result` field and a malformed/non-JSON line are handled without throwing past the interface. Prior art: the current `StreamParser` and `TranscriptParser` test suites in `AgentTests` — the relocated reader/event tests move with their types into `Transcript`'s test target and the new decoder tests sit beside them.
- **`TestChat` is not tested.** It is a throwaway whose purpose is manual, live evaluation; tests would only ossify code intended to be discarded.
- The `Transcript` extraction should leave `Agent`'s existing tests green with only the mechanical changes that follow a module move (imports, the widened writer visibility), demonstrating the refactor is behavior-preserving.

## Out of Scope

- `write` `AgentMode` and any worktree mutation; creating/removing isolated `git worktree`s for the Workflow.
- Live token streaming or any richer display (assistant text blocks, tool-use timeline). Final-answer-only for v1.
- An in-app Cancel button (depends on a separate `Agent` fix to give the `send`/resume path clean cancellation).
- The reusable production folder picker and deciding where it lives.
- A dedicated `Transcript` → display-messages reader module — defer until the real app reveals the shape it needs.
- Persistence/resume of `TestChat` sessions across app restarts; window state restoration handling.
- Shipping `TestChat` in release builds.

## Further Notes

- **ADR alignment.** ADR 0002 (transcript format) is preserved: `Agent` still writes claude's stream-json verbatim and owns only the four `hercules.*` framing types; the new decoders are consumer-side and live in `Transcript`. ADR 0001 (per-Turn `Harness` invocation) is what makes the buffered, re-parse-after-each-Turn read path correct, and the ~1–2 s bootstrap latency per Turn is acceptable for this chat UX.
- **Buffered-API consequence.** There is no live progress; a long Turn shows a spinner with no abort except closing the window (which discards everything). Acceptable for a throwaway; revisit if/when a streaming Agent API exists.
- **Domain framing.** The "throwaway session" is, precisely, a throwaway **Workflow** — one `Worktree` (the picked folder) plus one `Session` under a temp root — discarded wholesale on close.
- **Deep module.** `Transcript`'s decoder catalog is the deep module here: a small, stable interface (a Transcript line / bytes in → a typed event or a decoded answer out) hiding the messy reality of two mixed schemas, testable in isolation and reusable by the real app.
