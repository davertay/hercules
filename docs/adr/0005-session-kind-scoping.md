---
status: accepted
---

# One Session per (Workflow, kind), tagged on the Session row and rediscovered on construction

A Workflow's per-Workflow database (ADR 0003) holds the Turns of *every* surface that talks to a
Harness — the Design chat, the PRD chat, and the throwaway Test Chat all live in the same database.
To keep their conversations from bleeding into one another, each **Session** is tagged with a
**kind** identifying the surface it serves (`design`, `prd`, `testChat`), persisted on the `session`
row. The invariant is **one Session per (Workflow, kind)**.

A surface's chat is driven by a **Chat** engine constructed with its Workflow id and kind. Two moves
follow from the tag:

- **Scoped observation.** The engine observes only the Turns whose Session has its kind in its
  Workflow. The scope is fixed for the engine's lifetime, so a freshly-created Session's Turns are
  picked up automatically once its row exists — no re-subscription when the first Turn starts.
- **Rediscovery on construction.** The engine looks up the existing Session row for its
  `(Workflow, kind)` and reconstitutes the resumable Session from it: the row carries the pinned
  worktree and mode; the Skill files and added directories are fixed per surface and supplied by the
  consumer rather than persisted (ADR 0004). This single move fixes both *reopen-shows-history* (the
  reconstituted Session's prior Turns are already in scope) and the *resume-after-restart* gap (a
  follow-up resumes the rediscovered Session rather than starting a fresh one).

## Why / considered options

- **Tag the Session row with a kind (chosen).** The Session row is written at Session start — the
  earliest moment the surface is known — so the tag is available exactly when scoping and
  rediscovery need it. It is also the smallest change: one column plus a `kind` threaded through
  Session start.
- **Link the Session to a Phase via the Phase row (rejected).** A Session could instead be scoped by
  pointing it at its Phase. But the Phase row is created *lazily on completion* (it records a Phase's
  Artifact), so it does not exist while the conversation that produces that Artifact is still
  running — precisely when scoping is needed. Tagging the Session row is the smaller, earlier-
  available change.

## Consequences

- Supersedes the implicit single-Session-per-Workflow assumption: a Workflow may now hold several
  Sessions concurrently, disambiguated by kind.
- The `session` row gains a `kind` column (migration: default `design`, since any pre-existing row
  could only have been the Design Session). `Session`, `StartRequest`, and `recordSessionStart` all
  carry the kind through Session start.
- The Chat engine's conversation observation and Session rediscovery are both keyed on
  `(workflowID, kind)`; the lookup lives in the Store as `existingSession(workflowID:kind:)`.
