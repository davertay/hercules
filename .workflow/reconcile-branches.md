---
name: reconcile-branches
description: After a PR merges to main, merge the updated main into every other open agent branch so each PR stays current; resolve conflicts where possible, escalate to agent:blocked where not.
---

# /reconcile-branches

**Where:** workflow (`reconcile-branches.yml`).
**Trigger:** `pull_request: [closed]`, filtered to
`pull_request.merged == true && base.ref == 'main'`.
**Concurrency:** shares the `agent-serial-build` group with
`/implement-issue` — never runs alongside a build.

See [ISSUES.md](../ISSUES.md) for branch naming, the commit rules
(merge-only, never force-push, `claude[bot]` authorship), and the WIP cap.

## Why this exists

Open agent branches each forked from `main` at the moment they were created.
When one merges, the others drift behind and conflict at review/merge time.
This skill keeps every open agent PR continuously merged up to `main`, so the
human reviewer never has to resolve conflicts manually and CI always reflects
the branch *as it would land*.

## Steps

1. **List the branches to update.** Every other open agent PR:
   `gh pr list --state open --json number,headRefName` → keep heads matching
   `agent/issue-\d+`. (The just-merged PR is closed, so it's excluded
   automatically.) **Sort ascending by the issue number `N`** parsed from each
   branch, and process them in that order — lowest issue first. (Order doesn't
   affect correctness, since each branch merges `origin/main` independently,
   but ascending order makes runs deterministic and predictable.) If none →
   exit.

2. **Fetch.** `git fetch origin main` so `origin/main` is the freshly merged
   tip.

3. **For each branch `agent/issue-N`, in ascending `N` order:**

   a. `git checkout agent/issue-N` (it already tracks `origin/agent/issue-N`
      after the fetch; use `git checkout -B agent/issue-N origin/agent/issue-N`
      to be safe).

   b. **Merge main in, always as a merge commit:**
      `git merge --no-ff --no-edit origin/main`.
      - `--no-ff` guarantees the new HEAD is a `claude[bot]`-authored merge
        commit. This is what keeps `/ci-feedback`'s attempt-counter walk from
        falsely resetting on the human commits pulled in from main (the walk
        stops at the first `claude[bot]` commit, which is now HEAD). See
        [ISSUES.md](../ISSUES.md) > Attempt counter.

   c. **Clean merge** (exit 0): `git push origin agent/issue-N`. The push
      re-runs CI (the open PR's `synchronize` event) and re-fires
      `/ci-feedback`. No comment needed.

   d. **Conflicts** (merge stops with conflict markers): resolve them.
      - Read each conflicted file. Resolve to preserve **both** the branch's
        intent (the issue spec) and main's new reality. Don't blindly take one
        side. Match surrounding style; don't refactor unrelated code.
      - `git add` the resolved files, then `git commit --no-edit` to land the
        merge commit (authored by `claude[bot]`).
      - `git push origin agent/issue-N`.
      - Post a comment on the PR summarising what conflicted and how you
        resolved it, plus any assumption you had to make.

   e. **Unresolvable** (genuine semantic clash you can't safely reconcile —
      e.g. both sides redefined the same contract incompatibly):
      - `git merge --abort`.
      - Swap the issue's label `agent:in-progress`/`agent:done` →
        `agent:blocked`.
      - Post a comment on the PR: "Conflicts with `main` after #<merged PR>
        need manual resolution — escalating." List the conflicted files.
      - Move on to the next branch; one unresolvable branch must not block the
        others.

4. **Done.** Do **not** run the dispatcher here — a merge frees a WIP slot, and
   `/promote-waiting` (which also fires on this close) owns dispatching the
   next build.

## Notes

- **Merge, never rebase.** Rebase rewrites history and needs a force-push,
  which the commit rules forbid. A merge commit is correct here.
- Process branches independently. A failure on one (conflict, push reject)
  is isolated; continue with the rest.
- Idempotent: a branch already up to date with `main` merges as a no-op
  ("Already up to date") and is skipped — safe to re-run on every merge.
- This job runs Claude, so it shares the `agent-serial-build` serial group.
  Each invocation handles all branches in one session; with the WIP cap at 3
  that's at most 2 branches per merge.
