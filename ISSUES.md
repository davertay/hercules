# ISSUES.md

Operating manual for the automated issue → PR pipeline. All workflow skills
(`/triage-queue`, `/implement-issue`, `/ci-feedback`, `/promote-waiting`,
`/watchdog`) reference this document. Codebase conventions live in
[AGENTS.md](AGENTS.md); workflow mechanics live here.

## Labels

All `agent:*` labels live on the **issue**, never on the PR. The PR is
identified by its branch name (`agent/issue-N`) and by `Closes #N` in its body.

| Label | Meaning |
|-------|---------|
| `agent:queued` | Human signal: in the queue, awaiting dep-triage |
| `agent:pending` | Has unmet dependencies — waiting for another issue to close |
| `agent:ready` | Dependencies met, queued for agent pickup |
| `agent:in-progress` | Agent actively working; PR may or may not exist yet |
| `agent:done` | Agent finished, PR awaiting human review |
| `agent:blocked` | Needs human intervention |

### State transitions

```
(unlabelled)
    │ /queue-milestone or human
    ▼
agent:queued
    │ /triage-queue
    ▼
agent:pending ──── /promote-waiting (when deps close) ──── agent:ready
                                                              │ /implement-issue
                                                              ▼
                                                       agent:in-progress
                                                              │ /ci-feedback
                                            ┌─────────────────┴─────────────────┐
                                            ▼                                   ▼
                                       agent:done                          agent:blocked
                                            │                                   │ human unblock
                                            │ human merge                       ▼
                                            ▼                            (resume; see below)
                                       (closed)
```

## Branch naming

`agent/issue-N` where N is the issue number. Skills derive the linked issue
from the branch name (e.g., `/ci-feedback` parses `N` out of the PR's head
branch).

## Commits

- Incremental commits only.
- Never amend, never squash, never force-push.
- Commit author for agent-initiated work: `claude[bot]`. The
  `claude-code-action` runner sets git user to `claude[bot]` for every
  agent commit; the `WORKFLOW_PAT` only authorises the push. So
  pushes on agent branches are authored by `claude[bot]` and pushed by
  brucebruiser — `/ci-feedback` uses `claude[bot]` as the agent identity
  when distinguishing agent commits from human commits.

## PR conventions

- Open as ready, not draft.
- Body must include `Closes #N` so merge auto-closes the issue.
- Body must include an `## Assumptions made` section listing any agent
  assumptions (may be empty).
- No reviewer auto-assignment. Humans discover via the PR list.

## Acceptance criteria

- Section heading on the issue: `## Acceptance Criteria`
- Format: `- [ ] criterion text` (GitHub-flavoured checkboxes).
- The agent **never** edits the issue body's checkboxes. Authoritative state
  lives in the PR's status comment.
- Issues without an `## Acceptance Criteria` section: agent treats CI-green as
  sufficient; notes "no criteria found" in status comment.

## Dependencies

- Section heading on the issue: `## Dependencies`
- Format: `- #N` per line (one issue ref per bullet).
- Same-repo refs only (no `owner/repo#N`).
- Missing or empty section: treated as no deps → `agent:ready` after triage.
- Malformed section, or any referenced issue doesn't exist: `/triage-queue`
  blocks with an explainer comment.

## CI result protocol

- The `notify-agent` job in `ci.yml` posts a comment on every CI run, pass or
  fail.
- Comment includes `<!-- ci-result -->` marker on the first line.
- Header line includes `CI Result: Passed` or `CI Result: Failed`.
- Per-job status in a markdown table.
- Failed jobs: link to the full log (v1) or inline 200-line tail (v2 — not yet
  implemented).

## Status comment protocol

- Each PR has exactly one agent-owned status comment, identified by
  `<!-- agent-status -->`.
- `/implement-issue` posts the initial comment.
- `/ci-feedback` edits it in place each cycle (one comment, not a new comment
  per cycle).
- Source of truth for: agent state, attempt counter, last CI result,
  assumptions, criteria reasoning.

## Attempt counter

- Range: `1/3` to `3/3`.
- Stored in the status comment as `**Attempt:** N/3`.
- Incremented by `/ci-feedback` after each CI failure that triggers a fix
  push.
- Reset to 0 when a human commit (author != `claude[bot]`) is detected on the
  branch since the last agent commit.
- At 3/3 with a fresh failure → `agent:blocked`.

## Blocked → resumed protocol

Two unblock paths from `agent:blocked`, depending on where the failure
happened.

### State A — blocked before a branch exists

Triage failure, or `/implement-issue` couldn't proceed.

1. Human fixes the underlying problem (e.g., malformed Dependencies section).
2. Human removes `agent:blocked`.
3. Human re-applies `agent:queued` (triage-blocked) or `agent:ready`
   (implementation-blocked).
4. Normal workflow path resumes from that label.

### State B — blocked after 3 CI strikes

Branch and PR exist.

1. Human fixes the underlying code, commits, pushes to `agent/issue-N`.
2. Human removes `agent:blocked`.
3. CI runs on the push and posts a fresh `<!-- ci-result -->` comment.
4. `/ci-feedback` fires; first check: is `agent:blocked` still present? No →
   proceeds normally. Attempt counter resets because a human commit was
   detected since the last agent commit.
5. Race case: if CI lands before the human removed the label, `/ci-feedback`
   early-exits silently; the human pushes one more commit (or removes the
   label and pushes a no-op) to re-trigger.

## Status comment template

````markdown
<!-- agent-status -->
## Agent Status

**State:** in-progress  
**Attempt:** 1/3  
**Last CI:** —  
**Last failure:** —  
**Last updated:** 2026-05-23T14:30Z

### Assumptions
- [bulleted assumptions written by implement-issue; may be empty]

### Acceptance criteria
- [ ] criterion 1 text
  - _Reasoning:_ (filled in when CI passes)

### Attempt notes
1. Initial implementation: [one-line summary]
````

State fields are bold key-value pairs (parseable with
`\*\*State:\*\*\s+(\S+)` etc.). Narrative sections are free markdown.

## CI notify-agent comment template

````markdown
<!-- ci-result -->
## CI Result: Failed

**Commit:** `abc1234`  
**Run:** https://github.com/owner/repo/actions/runs/12345

### Jobs
| Job | Status |
|---|---|
| test-finance | passed |
| test-features | failed |
| build-app | skipped |

### Failed jobs
- test-features: [view log](https://github.com/owner/repo/actions/runs/12345)
````

Pass case omits the `### Failed jobs` section. Parsing: `CI Result:
(Passed|Failed)` in the header; per-job status from the table.

## Cascade triggering

GitHub Actions does not cascade-trigger workflows for events caused by the
default `GITHUB_TOKEN`. Any workflow write that should fire a downstream
job must therefore use a PAT — `secrets.WORKFLOW_PAT` in this repo.

- `claude-code-action` invocations in `claude.yml` pass `WORKFLOW_PAT`
  as `github_token`. Without this, agent label writes wouldn't fire any
  downstream job.
- `notify-agent` in `ci.yml` posts the `<!-- ci-result -->` comment via
  `WORKFLOW_PAT` (passed to `actions/github-script` as
  `github-token`). Without this, the CI result comment would post as
  `github-actions[bot]` but **never fire `ci-feedback`** — the dropped
  cascade looks identical to "everything is fine, just nobody reacted".

## Loop prevention

The state machine itself prevents loops: each label transition lands in a
state (`agent:in-progress`, `agent:done`, `agent:blocked`) that has no
workflow listener, so the agent's own writes cannot re-trigger the same
job.

`triage-queue` guards with `sender.login != 'brucebruiser'` as
defense-in-depth — `agent:queued` is a human signal, so brucebruiser-
authored events there indicate a misfire.

`implement-issue` and `ci-feedback` do NOT have the sender filter,
because their triggers (`agent:ready` label writes from triage-queue /
promote-waiting, and `<!-- ci-result -->` comments from notify-agent)
always have `sender=brucebruiser` by construction. Adding the filter
would kill the cascade. The body-contains check on `ci-feedback`
(`'<!-- ci-result -->'`) and the label match on `implement-issue`
(`agent:ready`) are sufficient gates.

`promote-waiting` triggers on `issues.closed` and intentionally has no
sender filter so it runs whether the closer is human or brucebruiser.
