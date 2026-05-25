---
name: triage-queue
description: Per-issue dependency triage. Parses `## Dependencies`, checks each ref, swaps `agent:queued` to `agent:ready`, `agent:pending`, or `agent:blocked` (with explainer comment for malformed deps).
---

# /triage-queue

**Where:** workflow (`claude.yml`).
**Trigger:** `issues: [labeled]`, filtered to
`label.name == 'agent:queued'` and `sender.login != 'brucebruiser'`.
**Scope:** per-issue — operates only on the issue that triggered.

See [ISSUES.md](../ISSUES.md) for the label state machine and the
`## Dependencies` format spec.

## Steps

1. **Read the issue body** for the triggering issue (`#${ISSUE_NUMBER}` from
   the workflow prompt).

2. **Locate the `## Dependencies` section.** Parse bullets of the form
   `- #N`. Strip whitespace; accept a trailing comment on the line.

3. **Handle parse errors.**
   - If a bullet doesn't match `- #\d+`, treat the section as malformed.
   - If a referenced issue doesn't exist in this repo (check via
     `gh issue view N --json state`), treat as malformed.
   - On malformed: remove `agent:queued`, add `agent:blocked`, post a
     comment listing which lines or refs were the problem. Exit.

4. **Check dep states.**
   - For each ref, `gh issue view N --json state` (or batch with `gh api`).
   - If all are `CLOSED` → remove `agent:queued`, add `agent:ready`.
   - If any are `OPEN` → remove `agent:queued`, add `agent:pending`.

5. **No `## Dependencies` section** (or section present but empty): treat as
   no deps → `agent:ready`.

## Notes

- Same-repo refs only. `owner/repo#N` is a parse error per ISSUES.md.
- Idempotent: if the issue arrives without `agent:queued`, exit early — the
  workflow filter should have prevented this but it's harmless.
- Don't comment on success cases; the label change is the signal.
- Don't edit the issue body. The agent never edits issue body content.
