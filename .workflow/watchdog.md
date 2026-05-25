---
name: watchdog
description: Hourly sweep for stale `agent:in-progress` issues. If a status comment hasn't been updated in 6+ hours, swap to `agent:blocked` and post an escalation comment.
---

# /watchdog

**Where:** scheduled workflow (`watchdog.yml`).
**Trigger:** `schedule: cron '0 * * * *'` (hourly) plus
`workflow_dispatch` for manual testing.

See [ISSUES.md](../ISSUES.md) for the status comment protocol and label
state machine.

## Steps

1. **Query all open issues** labelled `agent:in-progress`:
   `gh issue list --label agent:in-progress --state open --json number`.

2. **For each issue:**
   a. **Locate the linked PR.** Search for a PR whose head branch is
      `agent/issue-N`:
      `gh pr list --state open --head agent/issue-N --json number,comments`.

      If no PR exists, the run is stalled between `/implement-issue` step 8
      (push) and step 9 (post status comment) — rare but possible. Treat
      this as stale and escalate.

   b. **Read the agent status comment.** Find the comment whose body starts
      with `<!-- agent-status -->`. Inspect `updated_at` (the comment's
      timestamp, not the parsed `**Last updated:**` field).

   c. **Check staleness.** If `now - updated_at > 6 hours`:
      - Swap `agent:in-progress` → `agent:blocked` on the issue.
      - Post a comment on the issue:
        "Stalled run detected — no status update for >6h. See PR
        `agent/issue-N` for context."

3. **Done.**

## Notes

- Idempotent: an already-blocked issue no longer has `agent:in-progress`,
  so it's skipped on subsequent runs.
- Use the comment's HTTP `updated_at`, not the body field. The body field
  can drift if a manual edit happens; the HTTP timestamp is authoritative.
- 6 hours is a deliberate cliff — CI runs are short and `/ci-feedback`
  updates the status comment every cycle, so a 6h gap reliably indicates a
  stuck run (timeout, error in the action, lost workflow run, etc.).
- This skill does not attempt to recover — recovery is human work
  (resume via State A or State B per ISSUES.md).
