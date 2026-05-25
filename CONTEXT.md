# Hercules

Hercules is a macOS agentic coworking app. It launches and orchestrates AI Harness CLI processes
to do work on the user's behalf, and presents their output to the user.

## Language

### App-level

**Workflow**:
A stream of work applied to a repo — a refactor, a new feature, a debugging campaign. The
top-level unit of organisation in the app; deleting a Workflow deletes all its on-disk state in
one go. A Workflow bundles one **Worktree** and one or more **Sessions** under a single root
directory (`~/.hercules/workflows/<workflow-id>/`).
_Avoid_: Project (overloaded with Xcode/Swift project), task, job.

**Worktree**:
The git working tree the Workflow operates in. Created by the app (commonly as a `git worktree`
so changes are isolated from the user's primary checkout). Passed to the **Agent** module as
the **Harness**'s cwd at Session start; pinned on the Session for resume. One Workflow has one
Worktree; many Sessions in the Workflow share it.
_Avoid_: Checkout, repo (the worktree is a view of a repo, not the repo itself).

### Agent-level

**Agent**:
The local Swift module that owns the lifecycle of **Harness** subprocesses and exposes a typed
Swift API for talking to them. Knows nothing about **Workflows** — it operates purely on
**Sessions**. Also used informally for the LLM-side participant in a conversation (see
"Flagged ambiguities" below).
_Avoid_: Worker, runner, executor.

**Harness**:
The Claude Code CLI binary (`claude`) that the **Agent** module spawns as a subprocess. One
**Turn** = one Harness invocation.
_Avoid_: Claude (ambiguous with the model), CLI (too generic), process (implementation detail).

**Session**:
A resumable conversation, identified by a session ID (UUID) assigned by the **Harness** on the
first **Turn**. Pinned at start time to a **Worktree** and an **AgentMode**; these cannot
change across resumes. Sessions persist across app restarts via the Harness's own on-disk
storage plus the Agent module's per-Session data directory.
_Avoid_: Conversation (use for the user-facing concept only), thread, chat.

**Turn**:
A single user prompt plus the assistant response it elicits. Each Turn is one short-lived
Harness subprocess invocation. A Session is an ordered series of Turns.
_Avoid_: Message (a Turn contains multiple messages — user, assistant, tool calls), round, exchange.

**Transcript**:
The append-only file (one per Session) where Turn results are written as JSONL — a mix of
stream-json events passed through from the Harness verbatim and `hercules.*` framing lines
written by the Agent module (turn start, turn end, turn failed). Lives in the Session's data
directory, outside the Worktree, so it doesn't pollute `git status`.
_Avoid_: Log, history, output.

**AgentMode**:
The tool surface a Session is granted, pinned at Session start. `readOnly` strictly forbids
worktree-mutating tools (allowlist of Read/Grep/Glob/WebFetch/WebSearch only); `write` grants
full tool access. Cannot change across Turns within a Session.
_Avoid_: Permission level, scope, sandbox.

## Flagged ambiguities

**"Agent" — the module vs the LLM participant.** The Swift module is called `Agent`, and the
LLM-side participant in a chat is also called "the agent" in everyday speech ("user/agent chat
conversation"). When precision matters, prefer **Harness** for the subprocess and **assistant**
for the LLM-side speaker in the Transcript; reserve capitalised **Agent** for the module.

## Example dialogue

> **Dev:** When a user kicks off a new chat, what happens?
>
> **Domain:** The app creates (or reuses) a Workflow. Inside that Workflow there's a Worktree —
> a git worktree the agent will operate against. The app calls into the Agent module to start a
> Session: it passes the prompt, the worktree URL, the AgentMode (read-only or write), and a
> storage root (typically `<workflow-root>/sessions/`). The Agent spawns a Harness for the first
> Turn — one `claude` process with `--print --output-format stream-json --add-dir <inputs>
> --permission-mode bypassPermissions` and whichever tool restrictions the mode implies. The
> Harness emits a session ID early in its stream; we capture it, write a framing line to the
> Transcript, and after the Turn ends we return the Session to the caller.
>
> **Dev:** And when the user types a follow-up?
>
> **Domain:** That's a new Turn on the same Session. We spawn a fresh Harness with
> `--resume <session-id>` plus the same worktree cwd and the same mode-derived tool restrictions
> as the original. Its stream-json events get appended to the existing Transcript. From the
> user's point of view it looks like one continuous chat; from the Agent module's point of view
> it's two independent subprocess invocations bridged by the session ID and the pinned Session
> metadata.
>
> **Dev:** What if the same Workflow has multiple chat threads going at once?
>
> **Domain:** Multiple Sessions, same Worktree. Each Session has its own ID, its own data
> directory under `<workflow>/sessions/<session-id>/`, its own Transcript. They share the
> Worktree, so they can see each other's filesystem effects (if any are in write mode).
