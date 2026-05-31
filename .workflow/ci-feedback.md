---
name: ci-feedback
description: React to CI result comments. On failure, read logs and push a fix (up to 3 attempts); on success, reason per acceptance criterion and swap to `agent:done`. A cheap `ci-feedback-guard` job skips the run entirely when the linked issue is `agent:blocked`; this skill also re-checks the label as defense-in-depth.
---

# /ci-feedback

**Where:** workflow (`claude.yml`).
**Trigger:** `issue_comment: [created]`, filtered to comment body contains
`<!-- ci-result -->` and `sender.login != 'brucebruiser'`.

See [ISSUES.md](../ISSUES.md) for the CI result and status comment
protocols, the attempt counter rules, and the blocked → resumed paths.

## Steps

1. **Derive the linked issue number** from the PR branch name.
   - The triggering event is `issue_comment` on the PR; the prompt passes
     `PR #${PR_NUMBER}`.
   - `gh pr view <PR_NUMBER> --json headRefName` → parse `agent/issue-N`.
   - If the branch doesn't match `agent/issue-\d+`, exit silently — this
     isn't an agent PR.

2. **Read labels on the issue.** `gh issue view N --json labels`.
   - If `agent:blocked` is present → exit silently. The human hasn't
     finished unblocking yet (race case from State B step 5 in ISSUES.md).
   - The `ci-feedback-guard` job in `claude.yml` already gates this skill on
     the same label, so a blocked issue usually never reaches this run. This
     check stays as defense-in-depth for the narrow window where the label is
     applied after the guard passed but before this run reads it.

3. **Locate the agent status comment on the PR.**
   - `gh pr view <PR_NUMBER> --comments --json comments` and find the
     comment whose body starts with `<!-- agent-status -->`.
   - Parse the state block:
     - `**State:**\s+(\S+)` → current state
     - `**Attempt:**\s+(\d+)/3` → attempt counter
     - `**Last updated:**\s+(\S+)` → last update timestamp

4. **Detect human commits since the last agent commit.**
   - `git log agent/issue-N --format='%an %H'`
   - The agent's commits on this branch are authored by `claude[bot]`
     (the `claude-code-action` runner sets git user to `claude[bot]` —
     the `WORKFLOW_PAT` only authorises the push, it doesn't set
     commit authorship).
   - Walk backwards from HEAD until you hit a commit authored by
     `claude[bot]`.
   - If any commit between HEAD and that point is authored by someone
     other than `claude[bot]`, reset the attempt counter to 0.
   - If there are no `claude[bot]` commits on the branch yet (the
     implement-issue run hasn't completed), leave the counter as-is.

5. **Parse the CI result.** The triggering comment has
   `## CI Result: (Passed|Failed)` on its second line.

### If CI failed

a. **Increment** the attempt counter.

b. **If new count ≥ 3:**
   - Swap `agent:in-progress` → `agent:blocked` on the issue.
   - Update the status comment in place:
     - `State: blocked`
     - `Attempt: 3/3`
     - `Last CI: Failed`
     - `Last failure: <jobname(s)>`
     - `Last updated: <now>`
     - Append a new line to `### Attempt notes`:
       `3. CI failed three times — escalating to human.`
   - Exit.

c. **Else (1/3 or 2/3):**
   - Fetch failure detail. The CI comment links to the run URL; use
     `gh run view <run_id> --log-failed` (parse run id from URL) to get
     failed step logs.
   - Diagnose. Make a minimal fix. Commit, push.
   - Update the status comment in place:
     - `Attempt: <new_count>/3`
     - `Last CI: Failed`
     - `Last failure: <jobname(s)> — <short cause>`
     - `Last updated: <now>`
     - Append: `<new_count>. Fix attempt: <one-line summary>`

### If CI passed

a. **Read `## Acceptance Criteria`** from the issue body.

b. **For each criterion**, reason against the cumulative diff
   (`git diff main...agent/issue-N`). Update the status comment's
   `### Acceptance criteria` section:
   - If the diff clearly satisfies the criterion → tick the box
     (`- [x]`) and fill in `_Reasoning: ..._` below it.
   - If ambiguous → leave the box unchecked and write
     `_Reasoning: ambiguous — <why>_`.

c. **If no `## Acceptance Criteria` section** exists on the issue, replace
   the criteria section with a single line:
   `_No acceptance criteria found in issue body; relying on CI pass._`

d. **Swap** `agent:in-progress` → `agent:done` on the issue.

e. **Update** the status comment:
   - `State: done`
   - `Last CI: Passed`
   - `Last updated: <now>`

## Notes

- Edit the existing status comment via `gh api -X PATCH
  /repos/{owner}/{repo}/issues/comments/<id> -f body=...`. Don't post a new
  comment per cycle.
- Don't edit the issue body's checkboxes — authoritative state lives in the
  status comment.
- The `<!-- agent-status -->` marker must remain on the first line after
  every edit so the next invocation can still find the comment.
- Fix commits go on the `agent/issue-N` branch; CI re-runs on the push and
  posts a fresh `<!-- ci-result -->` comment, which re-triggers this skill.
- If the run URL log fetch fails (permissions, transient API error), still
  attempt a diagnosis from any details in the comment itself, and note the
  log-fetch failure in the attempt notes.
