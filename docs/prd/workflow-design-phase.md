# PRD: Workflow window + Design Phase (first feature)

> Status: draft (not published to the issue tracker). Captures the design agreed in a grilling
> session. Frames the whole Workflow window, then carves out the **Design Phase** as the first
> vertical slice to build; the other four Phases are placeholders for now.

## Problem Statement

Hercules can drive a real `Harness` end-to-end (the TestChat PoC proved the loop), but it has no
product surface. The app's premise is to run a **Workflow** against a repo through five **Phases**
— Design → PRD → Allocate → Execute → Validate — each consuming the prior Phase's **Artifact** and
producing its own, ending in a branch the user can open a PR on. We need the **Workflow window**
(the container for all five Phases) and the first Phase, **Design**, working end to end: the user
opens a new Workflow, lands on Design, is asked "what are we building today?", chats back and forth
under the grill-me **Skill**, and on conclusion gets a markdown **summary** saved as the Artifact
that the PRD Phase will later consume.

Building this on the TestChat PoC's buffered, re-parse-after-each-Turn model would mean a UI that
can't stream and a transcript split between a file and a database — two sources the UI would have
to reconcile. So this feature also lays the real data foundation: a per-Workflow database the UI
observes directly, fed live by the Agent.

## Solution

A **walking skeleton on the real architecture** — the thinnest end-to-end Design slice, every line
of it production code, then iterate to fill in depth.

**Data layer (`Store`, evolved from `Transcript`).** The `Transcript` infrastructure module grows
into the data layer (drops its Foundation-only constraint; gains `sqlite-data` /
`swift-structured-queries`). It owns **one SQLite database per Workflow**, living in the Workflow
directory (`~/.hercules/workflows/<id>/`), with a sync-ready schema (UUID primary keys,
`createdAt`/`updatedAt`, soft-delete; CloudKit **not** enabled yet): tables for `workflow`, `phase`
(status + `artifactPath` + timestamps), `session`, `turn`, and `content_block`. It exposes the live
**projector** (stream-json events → coalesced rows) and observation queries. Dependency direction
stays one-way: `Agent` → `Store`.

**Agent (streaming).** The Agent switches from buffer-then-write to **streaming** consumption of
`Harness` stdout, projecting each line into the Workflow DB as it arrives: one row per content
block (assistant text, tool call, tool result, thinking), with streamed text/JSON deltas coalesced
in memory and flushed to the row in place on a throttle, reconciled against the consolidated
`assistant`/`user` message, and finalized into a `turn` row on the `result` event. `AgentClient`'s
`start`/`send` take a handle to the Workflow's `Store` (replacing `storageRoot`), plus
`skillFiles: [URL]` and a list of `--add-dir` directories. The JSONL transcript is dropped (ADR
0003 supersedes 0002).

**WorkflowContainer (feature).** One window per Workflow (value-driven `WindowGroup` keyed on the
Workflow id), a `NavigationSplitView` with all five Phases in the sidebar and the selected Phase in
the detail. The container owns an `@Observable` workflow model, observes the `phase` rows for
**reactive gating** (a Phase unlocks when the Artifact it consumes exists), and constructs the
`Design` view directly (importing it) with built-in locked/placeholder views for the other four.

**Design (feature).** Intake empty-state ("What are we building today?") → first submit starts a
`readOnly` Session (cwd = the repo) under the grill-me **Skill** → a **streaming chat** built fresh
in `Design`, rendered by observing the Workflow DB → a **"Generate Design Summary"** action runs a
finalization Turn whose final answer is written to `phases/design/summary.md` and flips the Design
`phase` row to complete → a **saved confirmation with a Reveal-in-Finder** button (the user edits
the summary externally if they wish).

**App.** A real **New Workflow** command (File ▸ New, plus a launch-view button): folder-pick the
repo, create the Workflow directory + initialized DB + metadata, open the window on Design. The
grill-me Skill ships as an app-bundle resource.

## User Stories

1. As a user, I want to create a new Workflow by picking a repo folder, so that I can start work
   against a real codebase.
2. As a user, I want each new Workflow to open in its own window showing the five Phases in a
   sidebar, so that I can see the whole journey.
3. As a user, I want Phases I can't start yet to appear locked, and to unlock automatically when
   their input is ready, so that the pipeline order is clear without me managing it.
4. As a user, I want Design to greet me with "What are we building today?", so that I know how to
   begin.
5. As a user, I want my first message to start a grilling conversation under the grill-me Skill, so
   that the agent interrogates my idea instead of just answering.
6. As a user, I want the agent able to read (not modify) my repo during Design, so that it can
   ground and challenge the design against the real code.
7. As a user, I want the assistant's response to stream in as it's produced, so that the chat feels
   live rather than frozen until the Turn ends.
8. As a user, I want to send follow-ups on the same Session, so that the grilling is a continuous
   conversation.
9. As a user, I want a "Generate Design Summary" action, so that I decide when the design is done.
10. As a user, I want the summary saved to disk as a markdown file, so that it persists as the
    Phase's Artifact.
11. As a user, I want a confirmation and a Reveal-in-Finder button when the summary is saved, so
    that I can open and edit it in my own tools.
12. As a user, I want producing the summary to mark Design complete and unlock PRD, so that I can
    see the Workflow advance.
13. As a user, I want my Workflow's conversation and state to persist on disk, so that nothing is
    lost when I close the window.
14. As a developer, I want the transcript stored as observable DB rows fed live by the Agent, so
    that the UI has a single reactive source.

## Implementation Decisions

**Sequencing**
- Walking skeleton first: minimal-but-real schema, streaming projection for **text** blocks only,
  `WorkflowContainer` with Design + locked placeholders, finalization/Artifact, New Workflow. Then
  iterate: tool/thinking-block rendering, gating polish, richer placeholders. The riskiest piece
  (live streaming projection) is proven first, inside a working loop.

**`Store` (data layer)**
- Evolve `Transcript`; do not add a second data module. One SQLite DB per Workflow, in the Workflow
  directory, so deletion stays a single `rm` of the directory and there is no global DB to manage.
- Sync-ready schema now (UUID keys, timestamps, soft-delete); CloudKit deferred.
- Keep the existing value types (`Session`, `AgentMode`) and the consumer-side stream-json decoders
  in this module; add the schema, the live projector, and observation queries. May be renamed
  `Store`.

**Agent (streaming projection)**
- Stream `Harness` stdout line-by-line; project to rows live. Coalesce `content_block_delta` in
  memory, flush throttled (~50–100 ms + a final flush on `content_block_stop`); never store
  individual deltas. Reconcile each block against the consolidated `assistant`/`user` message
  (authoritative). Finalize the Turn from the `result` event (final answer, `is_error`,
  `duration_ms`, cost, usage).
- `AgentClient.start/send` take a `Store` handle (replaces `storageRoot`), `skillFiles: [URL]`
  (→ one `--append-system-prompt-file` each), and multiple `--add-dir` directories. The four
  `hercules.*` framing events become `session`/`turn` rows rather than file lines.

**`WorkflowContainer`**
- A composing **feature** module (per the revised `lib/AGENTS.md`: a window that composes other
  features is itself a feature module). It imports `Design` directly; no factory injection. It
  renders the locked/placeholder Phases itself and switches to `Design` for the Design Phase.
- Gating is reactive: observe `phase` rows; a Phase is enabled once the Artifact it consumes exists.

**Design Phase**
- `readOnly` `AgentMode`; cwd = the selected repo folder; no `git worktree` created yet (deferred to
  Execute, which needs `write`).
- Skill = grill-me, injected via `--append-system-prompt-file` (ADR 0004), with `--add-dir` for the
  skill's directory so the agent can read its referenced files.
- Conclusion is a **user-triggered finalization Turn**: a "Generate Design Summary" button resumes
  the Session with a canned "write the summary now" instruction; that Turn's final answer is saved
  as `phases/design/summary.md`. grill-me steers toward closure conversationally; the user decides
  when. Re-running regenerates/overwrites.
- Summary presentation: saved confirmation + **Reveal in Finder**
  (`NSWorkspace.activateFileViewerSelecting`); no in-app rendering or editing in v1.
- Chat UI built fresh in `Design`, observing the DB (streaming). TestChat is left as the throwaway
  it is; a shared `ChatUI` infra module is deferred until a second Phase needs chat.

**App / New Workflow**
- Real File ▸ New command + a launch-view button. Folder-pick → create
  `~/.hercules/workflows/<id>/` + initialize the DB + write a `workflow` metadata row (repo path,
  created) → open the window on Design.
- The grill-me Skill is bundled as an app-target resource.

## Testing Decisions

- `Store` and the Agent's projection are **tested** — they are durable production code. Unit-test
  the projector: text-delta coalescing into one block row; reconciliation against the consolidated
  message; tool-use / tool-result / thinking blocks mapped to rows; `result` finalizing the `turn`;
  malformed/non-JSON lines handled without throwing past the interface. Reuse the posture of the
  existing `Agent`/`Transcript` suites (Swift Testing, `withDependencies`, snapshots where shape
  matters); the relocated reader/event tests move with their types into `Store`'s test target.
- `WorkflowContainer` gating logic is tested (given phase rows, the right Phases are
  enabled/locked).
- The `Design` view follows the codebase's usual UI-test posture; assert external behavior through
  the module interface, not implementation details.

## Out of Scope

- The PRD, Allocate, Execute, and Validate Phases (placeholders only); the Validate → Execute loop;
  Issue tickets beyond reserving schema space.
- `write` `AgentMode` and `git worktree` creation/isolation.
- A Workflows-list / browse / reopen / delete "home" surface (the on-disk + DB design supports it;
  build it as a fast-follow).
- CloudKit sync (schema is sync-ready; sync is not turned on).
- In-app rendering or editing of the summary; tool/thinking-block rendering in the first slice.
- Extracting a shared `ChatUI` module.

## Further Notes

- **ADR alignment.** ADR 0001 (fresh `Harness` per Turn) is unchanged — only the within-Turn IO
  model becomes streaming. ADR 0003 makes the per-Workflow DB the live transcript store and
  supersedes ADR 0002 (the JSONL file). ADR 0004 fixes the Skill-injection mechanism.
- **Glossary.** This feature introduced/redefined **Phase**, **Artifact**, **Skill**, and
  **Transcript** in `CONTEXT.md`; "persona" is reserved for the Validate review personas.
- **Why a per-Workflow DB.** Cleanup stays a directory delete; sync (later) is naturally
  per-Workflow; the Workflow *list* is filesystem-derived (enumerate the directory) while each
  Workflow's contents live in its own DB — no global database to migrate.
