# PRD: Allocate Phase — PRD + Design → Issues via an MCP write tool

> Status: draft (not published to the issue tracker). Captures the design agreed in a grilling
> session, the new domain term in [CONTEXT.md](../../CONTEXT.md) (**Issue**), and the rationale in
> [ADR 0006](../adr/0006-mcp-write-tools-via-stdio-store-bridge.md). Builds the third Phase of the
> Workflow, after Design and PRD; Execute and Validate remain placeholders.

## Problem Statement

A Workflow can now produce a Design **summary** and a **PRD**, but nothing turns that prose into
work an Agent can actually pick up and do. The **Allocate** Phase is the missing link: it should
take the PRD and Design summary and break the implementation down into bite-size **Issues** — each
small enough for an Agent to complete in one shot — recording them as structured, queryable data
the Execute Phase can later work through in dependency order.

Two things make this Phase different from Design and PRD, and both need solving:

1. **The Artifact is structured, not a document.** Design and PRD each end in a markdown file the
   host writes from the Turn's final answer. Allocate's Artifact is a *set of rows* in the Workflow
   database — potentially a dozen or more Issues, each with a title, a body of spec, a number, and
   dependencies on other Issues. Parsing that many records out of a free-form final answer is
   brittle; we want a structured, validated path from the agent's intent to the rows.

2. **The user must confirm before anything is written.** Splitting work into Issues is a judgement
   call the user should review and adjust ("split that one", "these two should merge", "#7 depends
   on #5") *before* the Issues are committed. So unlike PRD's fire-and-forget one-shot, Allocate
   needs a conversation, and an explicit commit step.

## Solution

The Allocate Phase is a **hybrid of the two existing Phase shapes**: a directed kickoff button
(like PRD) plus a chat composer (like Design), with a **two-button, button-gated commit**.

**The flow the user sees.** Allocate unlocks once PRD completes. The user lands on an intake state
with a single action, **Propose Issues from PRD & Design**. Pressing it runs a proposal Turn: the
agent reads both Artifacts and the repo (grounding the Issue sizing in real code) and presents the
proposed Issue list as plain text in the chat — no Issues are written yet. The user iterates through
the composer ("split #4", "#7 should depend on #5"); each message is a normal follow-up Turn, still
text only. When satisfied, the user presses **Accept & Write Issues**. The host clears any existing
Allocate Issues for the Workflow, then runs a commit Turn that instructs the agent to write the
agreed set. When that Turn returns, the Issue list appears with a saved confirmation ("12 Issues
created"), the Allocate **Phase** row flips to complete, and **Execute** unlocks.

**How Issues reach the database — a Store-bridged MCP write tool.** Rather than parse the final
answer, the agent writes each Issue itself by calling a custom MCP tool,
`mcp__hercules__create_issue` (one call per Issue: `number`, `title`, `body`, `dependencies`). The
tool is served by a **stdio MCP server** that the `Harness` spawns per Turn. That server is **the
Hercules app binary re-executed with a subcommand** — it branches at `@main` before any AppKit
setup, opens the named Workflow database, and inserts rows. The app process and the server never
talk directly: the **shared SQLite Store is the only channel**. The tool's handler is app code
linking `Store`, so every insert is transactional and uses the real `IssueRow` type and ADR 0003
sync columns — the model supplies content, never raw rows, and (because the DB path and workflow id
are launch arguments, not tool arguments) can never target another Workflow. This is the first MCP
infrastructure in the app; the pattern is intended to generalise to the blocking `ask_user` tool
(#71). See [ADR 0006](../adr/0006-mcp-write-tools-via-stdio-store-bridge.md) for the C1-stdio,
re-exec-self, and official-SDK decisions and their rejected alternatives.

## User Stories

1. As a developer, I want the Allocate Phase to unlock once the PRD Phase is complete, so that I
   can only break work down once there is a PRD and Design summary to break down.
2. As a developer, I want the Allocate Phase to stay locked with an explanatory placeholder until
   PRD completes, so that I understand what I need to finish first.
3. As a developer, I want a single **Propose Issues from PRD & Design** action on the intake
   screen, so that I can start the breakdown without typing an opening prompt.
4. As a developer, I want the proposal Turn to read both the PRD and the Design summary, so that the
   Issues reflect the full agreed scope, not just one document.
5. As a developer, I want the agent to ground Issue sizing in the actual repo, so that each Issue is
   genuinely a one-shot-sized piece of work against the real codebase.
6. As a developer, I want the proposed Issue list presented as plain text in the chat first, so that
   I can review the breakdown before anything is committed.
7. As a developer, I want each proposed Issue to show its number, title, a body of spec, and its
   dependencies, so that I can judge whether the breakdown and ordering are right.
8. As a developer, I want to refine the proposal through the chat composer ("split #4", "merge 2 and
   3", "#7 depends on #5"), so that I can shape the breakdown conversationally.
9. As a developer, I want each refinement to be a normal follow-up Turn that resumes the same
   conversation, so that the agent keeps the full context of what we have agreed so far.
10. As a developer, I want no Issues written to the database while we are still proposing and
    refining, so that an in-progress discussion never leaves half-baked records behind.
11. As a developer, I want an explicit **Accept & Write Issues** action, so that committing the
    breakdown is a deliberate step and not something that happens because I typed "looks good".
12. As a developer, I want accepting to first clear any previously written Allocate Issues for this
    Workflow, so that re-committing replaces the set cleanly instead of piling duplicates on top.
13. As a developer, I want the commit Turn to write each agreed Issue via the create-issue tool, so
    that the records are structured and validated rather than parsed out of prose.
14. As a developer, I want each Issue to carry the agent-assigned number it was proposed under, so
    that the dependencies I reviewed still line up after the write.
15. As a developer, I want each Issue's dependencies recorded as the set of other Issue numbers it
    depends on, so that the Execute Phase can later work them in dependency order.
16. As a developer, I want each Issue to start with a status of "new", so that the Execute Phase has
    a defined starting lifecycle state to advance from.
17. As a developer, I want the Issue list to appear with a saved confirmation when the commit Turn
    finishes, so that I get clear feedback that the breakdown was recorded.
18. As a developer, I want the Allocate Phase to be marked complete once Issues exist, so that the
    Execute Phase unlocks.
19. As a developer, I want completion gated on the commit Turn actually producing at least one
    Issue, so that a Turn that wrote nothing does not falsely unlock Execute.
20. As a developer, I want to re-open the Workflow window later and still see the Issues that were
    written, so that the breakdown is durable across app restarts.
21. As a developer, I want to re-run the proposal after completing (re-propose and re-accept), so
    that I can regenerate the breakdown if the PRD or Design summary changed.
22. As a developer, I want re-committing to replace the prior Issues rather than accumulate them, so
    that there is always exactly one current Issue set per Workflow.
23. As a developer, I want the agent restricted from modifying the repository during Allocate, so
    that breaking work down can never accidentally change the code it is planning against.
24. As a developer, I want the create-issue tool to be unable to write to any Workflow other than
    the one I am working in, so that one Workflow's Allocate run can never corrupt another's data.
25. As a developer, I want the agent's chat — proposals, refinements, tool calls — to stream into
    the transcript like the other Phases, so that the Allocate surface feels consistent with Design
    and PRD.
26. As a developer, I want the Allocate conversation kept separate from the Design and PRD
    conversations in the same Workflow, so that the three Phases' transcripts never bleed together.
27. As a developer, I want the MCP server to reuse the exact same schema and migrations as the app,
    so that an Issue the agent writes is identical in shape to one the app would write itself.
28. As a developer, I want the proposal and commit prompts to be directed by the host with the
    behavioural detail living in the to-issues Skill, so that the heavy instructions are editable
    without recompiling.

## Implementation Decisions

**New `Issue` domain concept.** A bite-size unit of implementation work, the Allocate Phase's
structured Artifact, recorded as a row in the Workflow database. Captured in `CONTEXT.md`, including
the flagged ambiguity distinguishing an Allocate **Issue** from a Hercules-development **GitHub
issue**.

**`Store` — schema and helpers.**
- A new `issue` table following ADR 0003 conventions (UUID primary key, `createdAt`/`updatedAt`,
  `isDeleted`), with: `workflowID` (FK → `workflow`, indexed), `number` (Int, per-Workflow 1…N,
  agent-assigned), `title` (text), `body` (text — the bulk one-shot spec), `dependencies` (text
  holding a JSON array of the referenced `number`s — a distinct field, not a join table), and
  `status` (text, default `"new"`). Added via a new idempotent migration, not by editing the
  initial one.
- An `IssueRow` table type, public so both the app and the MCP server target use it.
- `clearIssues(workflowID:now:)` — soft-deletes (sets `isDeleted`) the Workflow's existing Issues.
- An issues fetch request (a `FetchKeyRequest`) returning a Workflow's non-deleted Issues ordered by
  `number`, mirroring `CompletedPRDPhaseRequest`.
- A `completePhase` overload that completes a Phase with **no** `artifactPath` (Allocate's Artifact
  is rows, not a file); the existing unlock gate keys only on `status == "complete"`.

**`IssueMCP` — the MCP server (new library target; depends on `Store`, `MCP`).**
- Built on the official `modelcontextprotocol/swift-sdk` (`from: 0.11.0`, product `MCP`): a `Server`
  with a `tools/list` handler declaring `create_issue` and a `tools/call` handler, served over
  `StdioTransport`.
- The tool handler is factored as a function over `(decoded create_issue arguments,
  DatabaseWriter, workflowID, clock)` that inserts one `IssueRow` (id and timestamps generated by
  the server, `status` defaulted to `"new"`, `workflowID` taken from the launch argument). This is
  the seam the tests drive, below the SDK transport.
- The DB path and workflow id arrive as **launch arguments** (`--db`, `--workflow-id`), fixed by the
  app and invisible to the model; the server opens that DB (migrations idempotent via
  `openWorkflowDatabase`) and writes only there.

**App entry point — re-exec self.** The Hercules app target's `@main` gains an argument branch:
when invoked with `--mcp-issue-server --db <path> --workflow-id <uuid>`, it runs the `IssueMCP`
stdio server loop and exits **before** initialising AppKit; otherwise it boots the GUI. The
`--mcp-config` handed to the `Harness` therefore points `command` at `Bundle.main.executableURL`.
No standalone helper binary is embedded or signed.

**`Agent` — threading the MCP server into a Turn.**
- A new `MCPServer` descriptor (`name`, `command`, `args`, `env`) is threaded through the request
  types, pinned on the `Session`, and re-passed on every resume Turn — exactly as `skillFiles` and
  `addDirs` are (ADR 0004 / ADR 0001).
- `Harness.renderArgs`, when servers are present, writes a per-Session `--mcp-config` JSON into the
  Session data directory and **derives the `--allowedTools` additions from the descriptors' tool
  names** (one source of truth: a tool can't be allowed without being configured). Rendering the
  mcp-config JSON is split into a pure function (separately testable) from writing the file.
- `AgentMode.readOnly` is unchanged in intent — it still forbids worktree-mutating tools — but its
  allowlist is extended by the derived MCP tool names. MCP tools write outside the worktree (into
  the database), so the worktree read-only guarantee holds. The Allocate Session is `readOnly` with
  `mcp__hercules__create_issue` added.

**`Chat` — `ChatEngine`.** `init` gains `mcpServers: [MCPServer] = []` (default empty, so Design,
PRD, and TestChat are unaffected), threaded into `StartRequest`/`SendRequest` alongside the existing
skill/dir parameters.

**`Material` — Skill.** A new `Skill.toIssues = "to-issues"` plus a placeholder
`Resources/skills/to-issues/SKILL.md` (the real behavioural instructions are authored later, as with
to-prd today). The Skill instructs: propose Issues as text only; write Issues via `create_issue`
only on the commit instruction; assign numbers 1…N and express dependencies as those numbers.

**`Allocate` — the Phase surface (new target; depends on `Agent`, `Chat`, `Material`, `Store`).**
- `SessionKind.allocate` added (ADR 0005); the engine observes only the Allocate Session's Turns.
- `AllocateModel`: owns a `ChatEngine` configured for `kind: .allocate`, `readOnly`, the to-issues
  Skill, the repo as worktree, and the `MCPServer` descriptor (command = the app binary, args = the
  Workflow DB path + workflow id). It reads the PRD and Design summary locations from their
  completed Phase rows (single source of truth). `propose()` runs one directed proposal Turn with
  both Artifacts as one `InputBundle` (root = the Workflow directory, the two `phases/...` paths as
  relative paths). `acceptAndWrite()` calls `clearIssues`, runs the directed commit Turn, then on
  return re-reads the Issues, and — if at least one exists — calls the nil-path `completePhase`.
- `AllocateView`: intake action, `ChatTranscript`, `ChatComposer`, the Issue list, and the
  Accept & Write / saved-confirmation banner — composed from the same building blocks as `PRDView`
  and `DesignView`.

**`WorkflowContainer` — wiring.** `WorkflowContainerModel` constructs an `AllocateModel` eagerly
alongside `DesignModel`/`PRDModel` under the scoped `defaultDatabase`; `WorkflowContainerView` routes
`.allocate` to `AllocateView`. The existing predecessor-based unlock gate already lights Allocate up
when `prd` completes — no gating change needed.

## Testing Decisions

Tests assert **external behaviour at the highest existing seam**, never implementation details. The
agent layer is exercised through the `agentClient` dependency (no real subprocess), and the MCP
server through its handler function (no real stdio), so tests are deterministic and fast.

- **`Store` (StoreTests).** Prior art: `FinalizationTests`, `WorkflowDatabaseTests`. Against a temp
  database: the `issue` migration applies (columns + index present) and `IssueRow` round-trips;
  `clearIssues` soft-deletes only the target Workflow's Issues (leaving other Workflows' Issues and
  already-deleted rows correct); the issues fetch request returns non-deleted Issues ordered by
  `number`; the nil-`artifactPath` `completePhase` overload completes the Phase with a null path and
  is observable by the existing completed-phase queries.
- **`IssueMCP` (new test target).** Prior art: the Store mutation tests. Drive the **tool-call
  handler** directly with decoded `create_issue` arguments and assert the inserted `IssueRow`
  (number/title/body/dependencies as given; `workflowID` from the launch context, not the
  arguments; `status == "new"`; id and timestamps from the injected `uuid`/`date` dependencies).
  Cover malformed arguments. The thin `@main` arg-branch that re-execs is not unit-tested; all
  logic lives in the library.
- **`Agent` — `Harness.renderArgs` (AgentTests).** Prior art: `HarnessRenderArgsTests` (snapshot +
  targeted `#expect`s). With an `MCPServer` descriptor: the args include `--mcp-config` pointing at
  the written path, and the allowlist is the `readOnly` base plus the derived tool name; with no
  descriptor, behaviour is unchanged. The pure mcp-config-JSON renderer is tested directly for the
  `{"mcpServers": {...}}` shape (command, args, env).
- **`Allocate` (new AllocateTests).** Prior art: `PRDModelTests`, `DesignModelTests` (mock
  `agentClient.start`/`.send`, inject `uuid`/`date`/`defaultDatabase`). `propose()` runs one
  `readOnly` Turn of kind `.allocate`, with both Artifacts as inputs, the to-issues Skill, and the
  `MCPServer` descriptor carrying the DB path + workflow id. `acceptAndWrite()` calls `clearIssues`
  before the commit Turn and `completePhase` (nil path) after — and only when a re-read finds at
  least one Issue (a commit Turn that wrote none does not complete the Phase). A test seeds Issue
  rows to stand in for the MCP child's writes. The to-issues Skill resolves from the bundle (as in
  the PRD test's Material-wiring check).
- **`WorkflowContainer` (WorkflowContainerTests).** Prior art: `PhaseGatingTests`. `.allocate` is
  locked until a completed `prd` Phase row exists, then unlocked.

## Out of Scope

- **The to-issues Skill's real instructions.** Shipped as a placeholder; the behavioural prompt is
  authored separately, as to-prd is today.
- **The Execute Phase** and anything that consumes Issues — topological ordering, advancing
  `status`, running Issues, opening PRs. Allocate only *creates* Issues.
- **Editing or deleting individual Issues from the UI.** The only mutation paths are propose →
  accept (write) and re-accept (clear + rewrite). No per-Issue edit/delete surface.
- **Live, row-by-row streaming of Issues as the child writes them.** Cross-process writes do not
  fire the app's `@Fetch`, so the list materialises when the commit Turn returns. A polling/live
  mechanism is explicitly deferred (ADR 0006).
- **The blocking `ask_user` MCP tool (#71).** This PRD establishes the MCP precedent but does not
  build a UI-blocking tool or an app-hosted (C2) server; #71 chooses its own transport.
- **A normalized `issue_dependency` join table.** Dependencies are a JSON array in a column by
  decision; a relational dependency model is out of scope.

## Further Notes

- **Soft enforcement of the propose/commit boundary.** The create-issue tool is allowlisted on
  *every* Allocate Turn (the allowlist is pinned per Session, not varied per Turn), so "don't write
  before commit" is enforced by the Skill, not the harness. This is safe: the host `clearIssues`
  immediately before the commit Turn, so any stray pre-commit write is discarded before the real
  set is written, and the host only re-reads after the commit Turn.
- **Cross-process concurrency.** During the commit Turn the MCP child is the only writer to the
  `issue` table; the app only reads. The host's `clearIssues` runs before the Turn starts, so there
  is no concurrent write to the same rows. SQLite (WAL) tolerates the two processes sharing the file.
- **Per ADR 0001**, the MCP server is spawned fresh for each Turn and is stateless ("open DB,
  insert, exit"); the `--mcp-config` is re-passed every resume Turn from Session-pinned state.
- **Dependencies added:** `modelcontextprotocol/swift-sdk` (`from: 0.11.0`) — the first non-Point-Free
  package and the first MCP dependency in the project.
