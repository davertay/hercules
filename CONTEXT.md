# Hercules

Hercules is a macOS agentic coworking app. It launches and orchestrates AI Harness CLI processes
to do work on the user's behalf, and presents their output to the user.

## Language

### App-level

**Workflow**:
A stream of work applied to a repo — a refactor, a new feature, a debugging campaign. The
top-level unit of organisation in the app; deleting a Workflow deletes all its on-disk state in
one go. A Workflow bundles one **Worktree**, one or more **Sessions**, the Phases' document
**Artifacts**, and a single per-Workflow SQLite database under one root directory
(`~/.hercules/workflows/<workflow-id>/`).
_Avoid_: Project (overloaded with Xcode/Swift project), task, job.

**Phase**:
One of the five named stages a Workflow moves through — Design, PRD, Allocate, Execute,
Validate. Each Phase consumes the prior Phase's output and produces its own; the set is fixed
and ordered. The left-hand sidebar of a Workflow window lists the Phases.
_Avoid_: Step (reads as atomic, and clashes with the per-issue units inside Execute), Stage.

**Artifact**:
A Phase's durable output, consumed as the next Phase's input. Document Artifacts (the Design
summary, the PRD) are markdown files in the Workflow directory; structured Artifacts (the Allocate
Issues) are rows in the Workflow's database. A Phase is unlocked once the Artifact it
consumes exists.
_Avoid_: Output, result, deliverable.

**Issue**:
A single bite-size unit of implementation work — small enough for an Agent to complete in one shot
— carved out of the PRD and Design summary by the Allocate Phase. The Allocate Phase's structured
Artifact: a row in the Workflow's database carrying the bulk of the spec as a text body alongside
distinct **number**, **title**, **dependencies**, and **status** fields. The Issues of a Workflow
form a dependency graph; the Execute Phase works them in dependency order.
_Avoid_: Ticket, task (reserve for everyday speech), story, GitHub issue (see Flagged ambiguities).

**Skill**:
A prompt document shipped in the app bundle that defines a Phase's agent behavior — grill-me for
Design, to-prd for PRD, to-issues for Allocate. Injected into the Harness as an appended system
prompt (`--append-system-prompt-file`) so it is always in force for that Phase's Session; the
skill's own directory is also exposed to the Harness (`--add-dir`) so the agent can read the
supporting files and scripts the skill references.
_Avoid_: Prompt (too generic), template, persona (reserve for the Validate review personas).

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
first **Turn**. Pinned at start time to a **Worktree**, an **AgentMode**, and a **kind** (the
surface it serves — Design, PRD, or TestChat); these cannot change across resumes. The kind scopes
the Session to one **Chat**, so several Sessions can share a Workflow's database without their
Turns bleeding together — one Session per (Workflow, kind) (ADR 0005). Sessions persist across app
restarts via the Harness's own on-disk storage plus the Agent module's per-Session data directory.
_Avoid_: Conversation (use for the user-facing concept only), thread, chat (lowercase — reserve
**Chat** for the user-facing surface below).

**Turn**:
A single user prompt plus the assistant response it elicits. Each Turn is one short-lived
Harness subprocess invocation. A Session is an ordered series of Turns.
_Avoid_: Message (a Turn contains multiple messages — user, assistant, tool calls), round, exchange.

**Transcript**:
The durable, query-able record of a Session's conversation — one row per content block (assistant
text, tool call, tool result, thinking) plus a per-Turn summary — held in the Workflow's SQLite
database and projected live from the Harness's stream-json as the Turn runs, so the UI streams
content in by observing the database. (The earlier append-only `transcript.jsonl` per Session,
ADR 0002, is demoted to at most an Agent-internal debug spool.)
_Avoid_: Log, history, output.

**Chat**:
The user-facing embodiment of a **Session** and its **Transcript** on one surface — what the user
sees and types into. A Chat engine is built with a Workflow id and a **kind**; it observes only the
Turns of that kind's Session in that Workflow, and on construction it rediscovers any existing
Session for the pair (so reopening shows prior history and a follow-up resumes; ADR 0005). A host
(e.g. the Design Phase) embeds a Chat and layers its own orchestration on top. Distinct from a
Session: the Session is the Agent-level resumable conversation; the Chat is its on-screen surface.
_Avoid_: Conversation (the everyday word for what a Chat shows), Session (the Agent-level concept).

**AgentMode**:
The tool surface a Session is granted, pinned at Session start. `readOnly` strictly forbids
worktree-mutating tools (base allowlist of Read/Grep/Glob/WebFetch/WebSearch); `write` grants
full tool access. A Session may additionally be granted non-worktree-mutating MCP tools — these
write outside the worktree (e.g. Issues into the Workflow database), so they extend a `readOnly`
Session's allowlist without breaking its worktree read-only guarantee. Cannot change across Turns
within a Session.
_Avoid_: Permission level, scope, sandbox.

### Validate Phase

**Persona**:
A named code-review agent in the Validate Phase, defined by its own **Skill** — e.g. Code Quality,
Security; the set grows as Skills are added. Runs read-only against the Worktree at the user's
discretion (each started manually, none required), produces a **Summary**, and may propose Issues.
Each Persona shows as one node in the Validate graph with a ready/running/done lifecycle. A static
description, not a per-run headline, labels the node.
_Avoid_: Reviewer, review agent, bot, validator.

**Review**:
One Persona's pass over the Worktree and its durable record — at most one per (Workflow, Persona),
overwritten when the Persona is re-run. Carries the run's lifecycle status and its **Summary**.
_Avoid_: Run, pass, scan, audit.

**Summary**:
The prose output of a **Review** — the Persona's findings, surfaced on demand from its node. There
is no separate headline; a Review yields one Summary.
_Avoid_: Headline, report, finding.

### Human-gated Issues

**HITL Issue**:
An Issue whose forward progress needs an explicit human decision rather than an Agent run. Its
status is one the Execute run loop refuses to auto-pick; it is resolved from the Execute DAG with a
positive control and a negative one. The negative always soft-deletes the Issue. Two kinds exist: a
**Proposed Issue** (from a Validate **Persona**) and a manual **Gate** (from Allocate).
_Avoid_: Blocked issue (reserve for an Issue waiting on its dependencies), approval.

**Proposed Issue**:
A **HITL Issue** a **Persona** creates during a **Review** to recommend a fix — status `proposed`,
with no dependencies and an Agent-assigned number. Approving it sets status `new` so the next Execute
run implements it; denying it soft-deletes it. A Persona proposes without asking.
_Avoid_: Suggested issue, draft, recommendation.

**Gate**:
A **HITL Issue** carved out in Allocate for work an Agent can't do (a manual step it must wait on).
The human marks it done — status goes straight to `done`, never running the Agent — which unblocks
its dependents; rejecting it soft-deletes it. Unlike a **Proposed Issue**, a Gate can be depended
upon. (Allocate-side; not built in the first Validate slice.)
_Avoid_: Manual issue, checkpoint, milestone.

## Flagged ambiguities

**"Agent" — the module vs the LLM participant.** The Swift module is called `Agent`, and the
LLM-side participant in a chat is also called "the agent" in everyday speech ("user/agent chat
conversation"). When precision matters, prefer **Harness** for the subprocess and **assistant**
for the LLM-side speaker in the Transcript; reserve capitalised **Agent** for the module.

**"Issue" — the Allocate Artifact vs a GitHub issue.** Hercules's own development tracks work as
GitHub issues (`ISSUES.md`). An Allocate **Issue** is a different thing: a row in a user Workflow's
database describing a unit of work on the *user's* repo. When precision matters, say "Allocate
Issue" for the Artifact and "GitHub issue" for the dev-process tickets.

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
