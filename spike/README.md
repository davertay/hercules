# `ask_user` spike logs

Raw evidence for [ADR 0008](../docs/adr/0008-blocking-ask-user-as-a-stdio-mcp-tool.md). Every measured
finding in that ADR points at a directory here.

These are recordings of a **third-party binary** — `claude` 2.1.260 and 2.1.261 on macOS 26.6.2, run on
2026-09-04 — kept so the ADR's reasoning can be audited rather than taken on trust. The CLI
auto-updated part-way through: **A and B ran on 2.1.260, C, D and E on 2.1.261.** Each run's
`server.log` records the `clientInfo.version` it saw, so the version is always recoverable from the
logs themselves. Nothing here is exercised by the test suite, and nothing here should be.

## The harness

A throwaway Python rig, kept at the top level: `server.py` (a stdio MCP server whose one tool blocks
until an answer file appears, logging every JSON-RPC message it receives), `driver.py` (spawns
`claude --print` in stream-json mode and keeps stdin open), `run_spike.py` and `run_e.py` (run one
experiment end to end and summarise it), `chain.py` and `d_launch.py` (the resume and teardown runs).
Per-run copies of `mcp.json`, `driver.py` and `server.py` sit inside the run directories that used
them.

In each run directory: `stdout.log` is the CLI's NDJSON stream, prefixed with seconds since launch;
`server.log` is the MCP server's view, with absolute timestamps; `session-id.txt`, `answer.txt`,
`stderr.log` and `driver.out` are the rest of the run's state.

## The runs

| Run | Question it answered |
|---|---|
| `A/` | Does a blocking MCP tool suspend a `--print` Turn, what does it cost, and what does the call carry? 204 s blocked, answered, same-turn continuation |
| `B/b1-*` | A sub-30 s idle timeout: when does the abort fire, and does the server hear about it? |
| `B/b2-*`, `B/b3-*` | Background-task env vars, with and without |
| `B/b4/` | The default idle timeout, left to fire |
| `C/c1/` | Is `AskUserQuestion` present in `--print`? (run without the MCP server, for the bare tool list) |
| `C/c2/` | Does `--disallowedTools AskUserQuestion` do anything? |
| `C/c3/` | Do `--settings` hooks work in `--print`? Settings for both the real matcher and the `Read` control are in `C/settings.json` and `C/settings-control.json` |
| `C/c4-1/` … `C/c4-5/` | Adoption under engineered conditions — a "MUST" steer and a prompt demanding a multiple-choice question |
| `D/d1/` | `kill -9` mid-call, then `--resume` |
| `D/d4/` | `SIGTERM` mid-call, then `--resume` |
| `D/d4b/` | The same, with the server left alive — isolating whose shutdown writes the result |
| `D/d5/` | Baseline: a normally answered call, then `--resume` |
| `E/e1/` … `E/e5/` | Adoption under deliberately weak conditions: the one-line `E/steer.md`, the real `mcp__hercules_ask__ask_user` name (unseen by the model), and a neutral brief that never mentions tools. `E/e1.txt` … `e5.txt` summarise each run; `E/steer.prior.md` is the stronger steer they replaced |
