---
status: accepted
---

# MCP write tools as a stdio server that re-execs the app and bridges through the Store

The Allocate Phase's agent turns the PRD and Design summary into **Issues** — rows in the Workflow
database. Rather than have the host parse a structured Issue list out of the Turn's final answer (the
mechanism Design and PRD use for their markdown Artifacts), the agent **writes the Issues itself
through a custom MCP tool**, `mcp__hercules__create_issue` (one call per Issue: `number`, `title`,
`body`, `dependencies`).

The tool is served by a **stdio MCP server** that the `claude` binary spawns per Turn. The server is
not a separate shipped executable: it is **the Hercules app binary re-executed with a subcommand**
(`--mcp-issue-server --db <workflow.sqlite> --workflow-id <uuid>`), branching at `@main` before any
AppKit initialisation. It opens the named Workflow database (migrations are idempotent;
`openWorkflowDatabase` is a no-op against an already-migrated file) and inserts `IssueRow`s. The app
process never talks to the server directly — **the shared SQLite Store is the only channel**: the
child writes Issue rows, and the host re-reads them when the commit Turn returns.

This is the first MCP infrastructure in the app and the first out-of-process writer to a Workflow
database; the pattern is intended to generalise to the blocking `ask_user` tool (#71).

## Why / considered options

### Getting Issues into the database: MCP write tool vs host-parses-final-answer

- **MCP `create_issue` tool (chosen).** A dozen-plus Issues emitted as free-form final-answer text
  is brittle to parse; structured, schema-validated tool arguments are not. The tool's *handler* is
  app code linking `Store`, so the insert is still host-controlled, transactional, and uses the real
  `IssueRow` type and ADR 0003 sync columns — the model supplies content, never raw rows. This keeps
  the determinism of host-side persistence while removing the parsing.
- **Host parses the final answer (rejected).** Consistent with Design/PRD, but a long Issue list is
  exactly the case where final-answer parsing is least reliable, and it puts a bespoke text format on
  the critical path.

### Transport: stdio child (C1) vs app-hosted HTTP/SSE server (C2)

- **stdio, spawned by `claude` (chosen).** No socket, no port, no listener, nothing to bind or
  secure — `claude` and the child talk JSON-RPC over the pipe. The write is one-directional (the tool
  inserts and returns; nothing waits on the UI), so the server being a *separate process* from the
  app costs nothing here. Per ADR 0001 the server is spawned fresh per Turn and is therefore
  stateless, which suits a "open DB, insert, exit" tool.
- **App-hosted HTTP/SSE server (rejected for now).** Would require an embedded localhost HTTP server
  (new dependency), ephemeral-port management threaded into each `--mcp-config`, a per-launch auth
  token, and an app-lifetime listener. Its one advantage — an in-process, in-memory handoff back to
  the tool call — only matters for a tool that *blocks on UI state*, i.e. `ask_user` (#71). Allocate
  needs none of it. #71 may still choose C2 (or a stdio child that polls the Store for the answer
  row) on its own merits.

### Server packaging: re-exec the app binary vs a standalone bundled helper

- **Re-exec the app binary with a subcommand (chosen).** `Bundle.main.executableURL` is always
  present and trivially resolvable, and the GUI binary already links `Store`. This deletes the entire
  problem of embedding, code-signing, and locating an SPM *executable* product inside an Xcode `.app`.
  Server logic lives in an `IssueMCP` library target; the app's entry point branches on the
  subcommand before `NSApplication`, so the CLI invocation never initialises AppKit. The cost is a
  heavier process than a purpose-built tool — negligible for a per-Turn tool call.
- **Standalone helper binary (rejected).** Cleaner separation, but embedding an SPM executable product
  in the Xcode app target is fiddly (build-phase to build and copy, nested-helper signing/notarisation)
  for no functional gain.

### MCP implementation: official SDK vs hand-rolled JSON-RPC

- **Official `modelcontextprotocol/swift-sdk` (`from: 0.11.0`, product `MCP`) (chosen).** Correct
  handshake (`initialize`/`tools/list`/`tools/call`) and protocol-version negotiation out of the box,
  and a real foundation for #71's additional tools. Swift 6 / macOS 13+, compatible with the toolchain.
- **Hand-rolled stdio loop (rejected).** Viable for one tool, but owning MCP-spec quirks by hand is
  needless risk once the Phase chain (and #71) wants more than one tool.

## Consequences

- A new `IssueMCP` library target (depends on `Store`, `MCP`) holds the server; the **app target's
  `@main` gains an arg-branch** that runs the stdio server and exits when the subcommand is present.
- The agent layer threads an `MCPServer` descriptor (`name`, `command`, `args`, `env`) through
  `ChatEngine → StartRequest → Harness`, pinned on the Session and re-passed on every resume Turn
  (per ADR 0001), exactly as `skillFiles`/`addDirs` are (ADR 0004). `Harness.renderArgs` writes the
  per-Session `--mcp-config` JSON into the Session data directory and **derives the `--allowedTools`
  additions from the descriptor's tool names** — one source of truth, so a tool can't be allowed
  without being configured.
- `AgentMode.readOnly` is extended: it keeps its worktree read-only guarantee but may additionally
  carry non-worktree-mutating MCP tools (they write to the database, not the worktree). The Allocate
  Session is `readOnly` with `mcp__hercules__create_issue` added.
- The DB path and `workflowID` are launch arguments fixed by the app, never tool arguments, so the
  model cannot direct writes at another Workflow.
- Cross-process writes do **not** fire the app's `@Fetch`/`ValueObservation` (it only observes its own
  connection's commits), so the Issue list updates **when the commit Turn returns** and the host
  re-reads, not row-by-row live. Re-running replaces the set: the host `clearIssues` (soft-delete)
  before the commit Turn.
- Establishes the precedent #71's blocking `ask_user` builds on; #71 must still decide transport,
  since its UI-blocking round-trip is the case that may justify C2.
