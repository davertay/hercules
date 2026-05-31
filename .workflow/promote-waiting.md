---
name: promote-waiting
description: After any issue closes, scan `agent:pending` issues and promote those whose deps are now all closed to `agent:ready`.
---

# /promote-waiting

**Where:** workflow (`claude.yml`).
**Trigger:** `issues: [closed]` — any close, by anyone, regardless of
whether via merge or manual close.

See [ISSUES.md](../ISSUES.md) for the `## Dependencies` format and the
label state machine.

## Steps

1. **Query all open issues** labelled `agent:pending`:
   `gh issue list --label agent:pending --state open --json number,body`.

2. **For each pending issue:**
   - Parse `## Dependencies` from the body.
   - For each `- #N` ref, check the issue's state.
   - If **all** referenced issues are now `CLOSED` → swap
     `agent:pending` → `agent:ready` on this issue.
   - If any remain open → leave the label alone.

3. **Dispatch the next build.** This close just merged a PR, freeing a WIP
   slot. Run the dispatcher from [ISSUES.md](../ISSUES.md) > Build dispatcher
   & WIP cap to start the next queued `agent:ready` issue if the cap allows.
   This is the step that resumes the serial queue after a merge — without it,
   newly-promoted (and previously dropped) `agent:ready` issues would sit idle
   because builds no longer start on their own `labeled` event alone.

4. **Done.** No comment needed; the label changes are the signal.

## Notes

- Idempotent: running multiple times on the same close event is harmless —
  it re-checks deps and only promotes issues that are now eligible.
- Don't restrict promotion to issues that reference the just-closed issue —
  the closed issue may have unblocked transitive dependencies. Scanning all
  `agent:pending` issues handles that with no extra logic.
- If the parse fails on a pending issue's `## Dependencies` (shouldn't
  happen because `/triage-queue` already validated it, but possible if the
  body was edited after triage), leave it as `agent:pending` and post a
  one-line comment flagging it. Don't block here — a separate human signal
  (re-applying `agent:queued`) will re-trigger triage.
