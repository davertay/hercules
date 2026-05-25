---
name: implement-issue
description: Create branch `agent/issue-N`, implement the issue spec, open a PR with `Closes #N` and an Assumptions section, and post the initial agent status comment.
---

# /implement-issue

**Where:** workflow (`claude.yml`).
**Trigger:** `issues: [labeled]`, filtered to `label.name == 'agent:ready'`.

See [AGENTS.md](../AGENTS.md) for codebase conventions and
[ISSUES.md](../ISSUES.md) for PR conventions, branch naming, and the
status comment template.

## Steps

1. **Race check.** `gh api repos/{owner}/{repo}/branches/agent/issue-N` (or
   `git ls-remote --heads origin agent/issue-N`). If the branch already
   exists → remove `agent:ready`, add `agent:blocked`, post a comment:
   "Branch `agent/issue-N` already exists from a prior run; manual
   intervention needed." Exit.

   (State A resume never hits this path because the branch wasn't created.
   This catches rare race / error cases.)

2. **Swap labels.** Remove `agent:ready`, add `agent:in-progress`.

3. **Create the branch.** `git checkout -b agent/issue-N` from `main`
   (HEAD of the default branch after fetch).

4. **Read the issue body in full.** It's the spec. Also read
   [AGENTS.md](../AGENTS.md) and [CONTEXT.md](../CONTEXT.md) for
   conventions and domain terms.

5. **Implement the code.** Match surrounding style. Don't refactor
   unrelated code. Add or update tests. Track anything you had to assume
   (about acceptance criteria, edge cases, library APIs you couldn't
   verify) — these go in the PR body and the status comment.

6. **Commit.** Incremental commits only. Never amend, never squash, never
   force-push. The `claude-code-action` runner sets git user to
   `claude[bot]`; the `WORKFLOW_PAT` authorises the push but does not
   change commit authorship. So commits on the branch will be authored by
   `claude[bot]` — that's the identity `/ci-feedback` looks for when
   distinguishing agent commits from human commits.

7. **Push** to `origin/agent/issue-N`.

8. **Open the PR** targeting `main`, as ready (not draft). Body must
   include:
   - `Closes #N`
   - Link back to the issue
   - `## Assumptions made` section listing assumptions (may be empty —
     write `- None.`)
   - Short summary of the change

   Use `gh pr create` with a HEREDOC for the body.

9. **Post the initial status comment** on the PR using the template from
   [ISSUES.md](../ISSUES.md):

   ````markdown
   <!-- agent-status -->
   ## Agent Status

   **State:** in-progress  
   **Attempt:** 1/3  
   **Last CI:** —  
   **Last failure:** —  
   **Last updated:** <ISO 8601 timestamp>

   ### Assumptions
   - [bulleted list; same as PR body's Assumptions made]

   ### Acceptance criteria
   - [ ] criterion 1 text
     - _Reasoning:_ (filled in when CI passes)

   ### Attempt notes
   1. Initial implementation: [one-line summary]
   ````

   The criteria list is copied verbatim from the issue's `## Acceptance
   Criteria` section if present. If absent, write a single line:
   `_No acceptance criteria found in issue body; relying on CI pass._`

## Notes

- The `<!-- agent-status -->` marker on the first line is how `/ci-feedback`
  finds and edits the comment in place.
- Don't edit the issue body's checkboxes — authoritative state lives in the
  PR's status comment.
- If the implementation is too ambiguous to attempt (issue body is
  effectively empty, or the scope is unintelligible), still create the
  branch and PR, but post the status comment with state `blocked`,
  swap the issue label to `agent:blocked`, and explain in the PR body. This
  is rare; normal flow has the human author write a usable spec.
