---
status: accepted (supersedes ADR-0002)
---

# Transcript stored as live-projected rows in a per-Workflow SQLite database

Each Workflow has a single SQLite database in its root directory. As a Turn runs, the Agent
consumes the Harness's stream-json **as a live stream** (not buffered to completion) and projects
it into that database: one row per content block (assistant text, tool call, tool result,
thinking), with streamed text/JSON deltas coalesced in memory and flushed to the row in place on a
throttle, plus a per-Turn summary row carrying the prompt, final answer, error flag, duration, and
cost. The UI renders by observing the database, so a Turn's content streams in as it is produced.

## Why

The earlier design (ADR 0002) wrote an append-only `transcript.jsonl` per Session and had the UI
re-read the file after each Turn. That cannot drive a real-time UI from a single source: the
buffered `AgentClient` returned only at Turn end, and a file-watching UI plus a separate database
would be two sources to reconcile. A per-Workflow database the UI observes directly is one
queryable, reactive source; doing the projection live during the Turn is what lets text and tool
activity appear as they happen.

The database is shaped to sync later (UUID primary keys, `createdAt`/`updatedAt`, soft-delete) but
CloudKit sync is **not** enabled yet. Document Artifacts (the Design summary, the PRD) and the
Worktree stay on the filesystem alongside the database, under the Workflow root, so deleting the
Workflow directory still removes all of a Workflow's state in one operation.

## Consequences

- The Agent's IO model changes from buffer-then-write to **streaming consumption** of Harness
  stdout. ADR 0001 (a fresh Harness subprocess per Turn) is unaffected — only what happens *within*
  a Turn changes.
- `transcript.jsonl` is dropped; the database is the sole sink. The raw verbatim stream-json is no
  longer retained, so a projection bug or a `claude` schema change cannot be recovered by
  re-projection — the projection must be correct at write time.
- Deltas are coalesced and written as per-content-block rows rather than stored individually,
  keeping row count and future sync volume small while still supporting token-by-token rendering.
- The four `hercules.*` framing events (ADR 0002) become columns/rows in the schema (Session and
  per-Turn rows) rather than lines in a file.
