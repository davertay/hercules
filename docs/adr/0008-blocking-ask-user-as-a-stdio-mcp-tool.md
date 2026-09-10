---
status: accepted
---

# Questions to the user as a blocking MCP tool on its own stdio server

An agent that needs a decision from the user asks for it by **calling a custom MCP tool that blocks
until the UI answers**, `mcp__hercules_ask__ask_user`. The handler suspends inside `tools/call`; the
app renders a card; the user's choice comes back as an ordinary `tool_result` and the model continues
**the same Turn**. This is the only mechanism that produces a clean `tool_use` → `tool_result` pair;
everything else on offer either cannot supply a result at all or supplies an error-shaped one.

The tool is served by a **stdio MCP server** — the app binary re-executed with a subcommand, the
[ADR 0006](0006-mcp-write-tools-via-stdio-store-bridge.md) pattern — under **its own server name,
`hercules_ask`**, distinct from the writers' `hercules`. The interface seam is a **question callback on
the Agent's requests** (`onQuestion` on `StartRequest`/`SendRequest`), which is what keeps the
transport replaceable: nothing above `Agent` learns that a subprocess, a directory or a poll interval
is involved.

The findings this rests on were measured against `claude` 2.1.260/2.1.261 on macOS 26.6.2 on
2026-09-04, and several of them **contradict what [ADR 0006](0006-mcp-write-tools-via-stdio-store-bridge.md)
and the originating issue (#71) expected**. They are recorded in full below, with the version each was
measured against, precisely so the next person does not rediscover them.

## The premise changed: this is a feature, not a bug fix

#71 was written to replace a mechanism that no longer exists. The Harness's built-in
`AskUserQuestion` is **absent from `--print` mode entirely** — not merely unrenderable, but missing
from the init tool list and from the deferred set. The model never calls it, so there is no auto-error,
no errored `tool_result`, and no failed Turn. What actually happens today is that the model asks in
prose and ends the Turn normally; the composer unlocks, the user replies, the next Turn resumes. That
works.

So the following original acceptance criteria describe a world that no longer exists and are
**struck**:

- no dangling errored tool call,
- no suppressed auto-error,
- pausing that is immune to stdout read timing.

The justification that remains is the one worth building for: **"that option, but with this tweak"**.
In a prose flow the user must retype the whole answer to qualify a choice; a card whose selection and
free-text note are separate fields makes qualifying a first-class path. That is impossible today and
cannot be obtained any other way. The lesser gains — same-turn continuation, a question that gates
rather than scrolls past, answers keyed by the model's own headers — are real but would not on their
own have justified this.

The machinery built for the old mechanism (`interruptedForQuestion`, the `AskUserQuestion` detector,
the auto-error suppression) was unreachable dead code and was deleted separately.

## Why / considered options

### The answer channel: an MCP tool, not hooks or Store rows

- **A blocking MCP tool (chosen).** The only mechanism that yields a well-formed call/result pair.
  The handler simply does not return until it has an answer, and the answer *is* the tool's result.
- **Hooks (rejected).** `PostToolUse` can rewrite the result of a call that *succeeded*; it cannot
  supply one for a call that never ran. `PreToolUse` can only allow or deny, so blocking in it and
  returning the answer as `permissionDecisionReason` yields an error-shaped denial — plus a hook
  timeout ceiling, where the MCP path has none once the idle timer is off.
- **Store-bridged "pending question" rows (rejected)** — #71's own leading option, and the one ADR
  0006 floated as an alternative to an in-process handoff. Two independent reasons. Correlating an
  answer to a call through the database invites a **stale answer being consumed by the wrong call** —
  a wrong answer attributed to the user, the worst failure this feature can produce — because the
  Harness abandons a call without telling the server. And a pending question is a live process holding
  an open request: persisting it means a crash leaves **zombie rows that render as answerable and are
  not**.
- **MCP elicitation, with the `Elicitation` hook (rejected).** Strictly more moving parts than
  blocking in the handler, and still requires an MCP server.

### Transport: stdio child, not an app-hosted HTTP/SSE server

[ADR 0006](0006-mcp-write-tools-via-stdio-store-bridge.md) chose stdio for the writers but explicitly
anticipated that *this* feature's UI round-trip might be the case that justifies an app-hosted
HTTP/SSE server with an in-process handler. **The measurements say otherwise, and that expectation is
superseded.**

- **stdio (chosen).** No socket, no port, no listener, no per-launch auth token, no app-lifetime
  server. Its idle grace is **thirty minutes** against HTTP/SSE's five — the wrong way round from what
  a human-latency tool would want if the timer mattered, and it does not once the timer is disabled.
- **App-hosted HTTP/SSE (rejected).** Its one advantage over stdio was an in-memory handoff back to
  the blocked call. The callback seam dissolves that advantage: the app→child channel is reduced to a
  private file protocol inside one module, and every caller above `Agent` sees an `async` function.
  Paying for an embedded HTTP server, ephemeral-port management and a token to avoid writing one JSON
  file is not a trade worth making.

### Server name: `hercules_ask`, distinct from `hercules`

`Harness.mcpConfigJSON` keys entries by server name, and the per-Turn MCP override
([ADR 0001](0001-per-turn-harness-invocation.md)) **replaces rather than merges**. `ask_user` is pinned
on the Session, while the artifact writer arrives as a per-Turn override on the finalization Turn — so
under a shared name one would silently drop or collide with the other. Its own name yields
`mcp__hercules_ask__ask_user`, and the finalization call sites pass both descriptors: a last "did I
capture this right?" is plausible exactly there.

Consolidating the `hercules` servers into one multi-tool server whose launch flags declare which tools
it serves is a separate, later change.

### The seam: a question callback on the request

`send()` is already an `async` call that does not return until the Turn ends, so a blocking question
*is* a mid-call callback. Correlation becomes structural — one invocation, one answer. Cancellation is
returning a cancelled answer. Test doubles are trivial. An observable stream of pending questions was
rejected: it would put correlation, cleanup and "is this one still live?" back into every consumer.

`onQuestion` is optional, and `nil` — the default — leaves the Turn without the tool at all. That is
what an unattended run wants: a call blocking on an answer nobody is there to give would wedge the run
loop indefinitely, since the idle timer is off. Supplying a handler is how a caller says a human is
watching. The predicate is **"is this Turn attended"**, resolved per Turn rather than per Session kind,
so the planned session-takeover feature flips an input rather than rewriting a policy.

### Keeping the call alive: disable the idle timer

- **`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT=0` in the child environment (chosen).** Necessary and
  sufficient, and one line.
- **A progress-notification keepalive (rejected).** Would need the CLI to send a `progressToken` (it
  does) *and* the Swift MCP SDK to expose the notification path (unverified), in exchange for nothing
  over `=0`.
- **`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` / `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS` (not added).** No
  observable effect; there is no MCP auto-backgrounding on this build to disable. Shipping env vars
  that do nothing is a future reader's wild goose chase.
- **`--disallowedTools AskUserQuestion`, or a `PreToolUse` hook steering away from it (not added).**
  The flag is a silent no-op and the hook has nothing to match.

## Measured behaviour of the Harness

**These are observations of a third-party binary, on one machine, on one day — not facts about
Hercules, and not invariants.** They are recorded here so the reasoning above can be audited, and they
**must not be asserted in tests**: such a test would fail on someone else's machine, or on next week's
`claude`. Tests may assert what *we* pass and configure (that the child gets
`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT=0`, that the server is named `hercules_ask`), because that stays
true whatever the Harness does with it.

Measured on macOS 26.6.2, 2026-09-04. Note the version column: the CLI **auto-updated mid-spike**, from
2.1.260 to 2.1.261.

| Finding | Version |
|---|---|
| A blocking MCP tool suspends a `--print` Turn and the model continues in the **same Turn** when it returns: 204.1 s blocked, `is_error: false`, `num_turns: 3` | 2.1.260 |
| **Human think time is wall time, not API time** — `duration_ms: 214715` against `duration_api_ms: 11369`. Blocking costs no open API connection and no tokens | 2.1.260 |
| **No auto-backgrounding** at the two-minute mark: no task id, no notice, nothing distinguishing the boundary | 2.1.260 |
| Liveness is a `tool_progress` heartbeat **every 30 s**, carrying `parent_tool_use_id` — 6 of them over the block, at 39.8 s through 189.8 s | 2.1.260 |
| The call carries the Harness's **own tool-use id**: `_meta["claudecode/toolUseId"]`, matching the streamed `tool_use.id` exactly, plus a `progressToken` | 2.1.260 |
| **No MCP pings** during a 204 s call — the server received 4 messages in total across the whole run | 2.1.260 |
| The idle timeout fires at **1800.102 s** (call at 19:53:07.214Z, abort at 20:23:07.316Z) with an explicit message naming both the per-server `"timeout"` and `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` | 2.1.260 |
| `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT=0` disables it — a call blocked 264.7 s and returned cleanly | 2.1.260 |
| **Sub-30 s idle values quantise to the heartbeat tick**: with a smaller value configured the abort still fired at 30.009 s, and the message still said "30s" | 2.1.260 |
| **An abandoned call is never reported to the server** — no `notifications/cancelled`, nothing. After one such silent abort the model *retried*, and the retry never reached the handler at all: the server logged one `tools/call` and stayed blocked in it, and the second call aborted after its own silent 30 s | 2.1.260 |
| The background-task env vars have **no observable effect** — two otherwise-identical runs, differing only in those variables, behaved identically | 2.1.260 |
| **`AskUserQuestion` is absent from `--print`** — a 28-tool init list without our MCP server, 29 with it, and absent from the deferred set in both | 2.1.261 |
| `--disallowedTools AskUserQuestion` is **accepted without error and changes nothing** — a run with the flag and a run without it produce the identical 28-tool list, there being no such tool to disallow | 2.1.261 |
| `--settings` **hooks do work** in `--print` — a control matcher on `Read` fired, so the `AskUserQuestion` matcher's silence is "no target", not "broken". (The control run's own transcript was not preserved.) | 2.1.261 |
| MCP tools are **deferred, not listed**, and are reached by `ToolSearch` with the `select:` form and the **exact** qualified name (`total_deferred_tools: 17`) | 2.1.260/261 |
| Adoption, engineered conditions (prompt demanding a multiple-choice question, "MUST" steer): **5/5** routed to the MCP tool | 2.1.261 |
| Adoption, deliberately weak conditions (one-line steer, a tool name the model had never seen, a brief that never mentions tools): **5/5 routed to the tool, 0/5 asked in prose**, 3 `tools/call` per run, all blocked and unblocked | 2.1.261 |
| `SIGTERM` mid-call leaves **no dangling call**: claude's own shutdown closes the MCP transport and writes `"Connection closed"` / `is_error: true` as the `tool_result` (exit 143); resume is clean. Isolated in a follow-up run where the server was left alive and still blocked — so it is claude's shutdown path, not the server dying | 2.1.261 |
| `kill -9` mid-call leaves a **dangling `tool_use`** with no result, but `--resume` still works (exit 0): the CLI orphans the incomplete assistant turn by parent-pointer rewiring rather than erroring. Quietly destructive — the question is dropped from what the model is replayed — but not a failure | 2.1.261 |
| Side-finding, **carved separately**: under `--setting-sources user`, `Bash` calls succeeded although `Bash` was absent from `--allowedTools` — the user's own permission allowlist is loaded. Security-adjacent and unrelated to this decision, but it bounds what `AgentMode.readOnly` currently guarantees | 2.1.261 |

## Residual risks

- **Version dependence, and a question that is re-opened rather than settled.** `AskUserQuestion`
  existed when the earlier interrupt work was written and has since been withdrawn; the CLI
  auto-updated 2.1.260 → 2.1.261 *during the spike*. If the built-in returns, our tool is still the
  better option — it is the one that supports "that option, plus a tweak" — and the model has no
  reason to prefer the built-in over an explicitly steered tool. But the reasoning above should be
  re-read against the Harness of the day, not treated as settled.
- **The wedged server is the sharpest implementation hazard.** Because an abandoned call is never
  reported, a handler that blocks its transport read loop swallows every subsequent `tools/call`
  silently — the failure has no symptom other than a tool that stopped working. The handler therefore
  awaits concurrently and keeps serving the connection. With the idle timeout disabled the CLI should
  never abort a call at all, which is exactly how a permanently wedged server gets shipped: the hazard
  is only reachable if the timeout is ever re-enabled by managed settings or a future default.
- **`--append-system-prompt-file` is semi-documented.** It is accepted, but absent from `claude
  --help`'s option list (which mentions only `--append-system-prompt`). Hercules already depends on it
  for Skills ([ADR 0004](0004-skill-injection-via-append-system-prompt-file.md)); this adds a second
  dependence on it, for the house rules. The flag takes one file — the last given wins — so the house
  rules are composed with the Skill into a single file; shipped as a second flag, they silently
  displaced the Skill.
- **Adoption under vaguer briefs is untested.** Both adoption spikes used interview-shaped briefs.
  That is what the Design Phase's Skill actually instructs, so it is not a risk for the Phase this
  ships for — but 10/10 is a claim about interview-shaped work, not about all agents everywhere.
- **Every row in the table is one machine, one day.** They were reproduced across runs within the
  spike, not across machines, OS versions or accounts.

## Consequences

- `AgentClient`'s requests gain `onQuestion`, and it is the only thing a consumer supplies: attended
  Turns pass a handler, unattended Turns pass nothing and never see the tool. The MCP descriptor and
  the house-rules document travel as one value and attach together, since either alone fails silently.
- A third stdio MCP server, `hercules_ask`, alongside the two writers, and a `--mcp-ask-server`
  subcommand on the app binary. Turns that carry a writer carry both descriptors explicitly.
- The child environment gains `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT=0`, and **no Hercules-side deadline
  replaces it**: any value would be arbitrary, and an unanswered question is already visible — the
  Turn is on screen and Stop is in the toolbar.
- The house-rules document must name `mcp__hercules_ask__ask_user` **verbatim**, because MCP tools are
  deferred and reached by exact name. This is load-bearing, not stylistic.
- Pending questions live in the Turn's scratch directory and are **never persisted** to the Workflow
  database.
- Cancellation delivers an `is_error` result and then interrupts, rather than returning a polite "the
  user didn't answer" — a successful non-answer hands a well-behaved model permission to guess, which
  is the failure this feature exists to remove, reintroduced at the cancel path.
- Because `SIGTERM` already produces a well-formed transcript, the planned graceful-unwind state
  machine shrank to the card's own Cancel button. What was *not* already in place is teardown at all:
  app quit and window close now cancel their Turns, where before children were orphaned. Bounded
  before; unbounded once a tool can block forever.
