---
name: queue-milestone
description: Batching aid for curating coherent sets of work into a milestone. Filters open issues, confirms with the human, applies a milestone + `agent:queued` to each. Run locally — never invoked by a workflow.
---

# /queue-milestone

**Where:** local (human Claude Code session). NOT a workflow skill — the
workflow doesn't care about the source of `agent:queued`.

**Purpose:** convenience for batching a coherent set of issues onto a
milestone and into the agent queue. The human can skip this entirely and
apply `agent:queued` to individual issues by hand.

See [ISSUES.md](../../../ISSUES.md) for the full label state machine.

## Steps

1. **Ask the human for a filter.** Suggest a few axes:
   - Feature name or label (e.g., `area:projection`)
   - Existing milestone
   - Ad-hoc GitHub search criteria (e.g., `is:open is:issue label:bug`)

2. **Query open issues matching the filter.** Use `gh issue list`. Present
   the list to the human with title and number; ask for confirmation. Allow
   them to deselect individual issues.

3. **Apply a milestone.** Ask whether to use an existing milestone or create
   a new one; if creating, ask for the title and (optional) due date. Use
   `gh api` to create, then `gh issue edit <N> --milestone <title>` for each
   issue.

4. **Apply `agent:queued`.** `gh issue edit <N> --add-label agent:queued` for
   each selected issue.

5. **Report.** Print the final list of (number, title, milestone) tuples so
   the human can confirm the batch landed.

## Notes

- This skill performs writes via the human's own `gh` auth, not the WORKFLOW_PAT.
- `agent:queued` triggers `/triage-queue` in `claude.yml` on each issue. Once
  the labels are applied, the human's job is done; the workflow takes over.
- Idempotent: re-applying `agent:queued` to an issue that already has it is a
  no-op.
