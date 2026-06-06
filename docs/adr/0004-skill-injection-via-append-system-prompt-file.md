# Skills injected via --append-system-prompt-file

A Phase's **Skill** (a bundled markdown prompt such as grill-me) is injected into the Harness with
`--append-system-prompt-file <path>`, plus `--add-dir <skill-dir>` so the agent can read the
supporting files and scripts the skill references. The skill is pinned on the Session and
re-passed on every resume Turn.

## Why / considered options

- **`--append-system-prompt-file` (chosen).** Makes the skill always-on operating instructions on
  top of Claude Code's default system prompt — the right semantics for a conversation driver that
  must be in force every Turn. Passing a *file path* keeps argv tiny, so a skill of any size is
  safe against `ARG_MAX` (the inline `--append-system-prompt <text>` variant would risk it as
  skills grow). The CLI reads the file itself before the session starts, so it is not subject to
  the `--add-dir` tool-sandbox rules.
- **`--add-dir` + "read this file".** Reuses the existing `InputBundle` path, but the skill becomes
  a document the model is *advised* to read rather than enforced behavior — wrong for a driver that
  must always apply. Retained instead for genuine reference *documents* (e.g. the PRD Phase reading
  Design's `summary.md`).
- **Native Claude Code skill** (`.claude/skills/`, discovered via `--setting-sources`). Native
  skills are *model-invoked* (the model decides whether to use them), not always-on, and would
  require writing into a settings-source dir per Workflow.
- **stdin.** In `--print` mode stdin is the user-prompt channel (already used by `HarnessRunner`);
  it cannot carry a system prompt.

## Consequences

- `AgentClient` gains `skillFiles: [URL]` (one `--append-system-prompt-file` per file; an array
  composes skills) and accepts multiple `--add-dir` directories alongside the existing
  `InputBundle`.
- Per ADR 0001 (a fresh Harness process per Turn), the skill file path is re-passed on every Turn
  from Session-pinned state, so the skill stays in force across resumes.
