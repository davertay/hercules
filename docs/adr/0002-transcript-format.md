---
status: superseded by ADR-0003
---

# Transcript file format: passthrough stream-json + Hercules framing lines

Each Session has one Transcript file (`transcript.jsonl`) in its data directory. The file is
JSONL — one JSON object per line — but it contains **two distinct schemas** mixed together:

- **Passthrough lines:** stream-json events emitted by the Harness, written verbatim. Their
  schema is Anthropic's.
- **Framing lines:** events emitted by the Agent module itself, all with a `"type"` field
  prefixed `hercules.*` (`hercules.session.started`, `hercules.turn.started`,
  `hercules.turn.ended`, `hercules.turn.failed`). Their schema is ours.

A consumer reads the file line by line and discriminates by the `type` field: lines starting
with `hercules.` decode to a typed `HerculesEvent` enum we own; everything else is opaque
stream-json that the consumer parses with its own types.

## Why

The two main alternatives both lose something important:

- **Pure passthrough** — only the Harness's stream-json events go in the file — drops information
  we genuinely need to record. The user's prompt is *input* to the Harness, not part of its
  output, so it has no representation in the stream. Agent-level failures (process failed to
  spawn, crashed before emitting anything) likewise have no stream-json event. Without framing
  lines, the file isn't a complete record of the Session.
- **Curated chat format** — Agent module parses stream-json and writes its own typed structure —
  saddles us with chasing every claude release for schema changes, loses information (timestamps,
  message IDs, tool-use details, partial-message chunks) that may matter for debugging or future
  rendering, and turns the Agent module into a maintainer of someone else's format.

Mixing schemas in one file is the smallest design that captures everything once: stream-json
events for what the Harness said, framing lines for what we know that the Harness doesn't. The
`type` field gives consumers a trivial discriminator. We own a tiny stable vocabulary (4 framing
event types); claude owns its much larger vocabulary; neither has to track the other.

Each line is flushed (`fsync`) immediately on write, so a crash mid-Turn leaves a readable
Transcript up to the last completed event — including the `turn.failed` framing line if the
Agent module surfaced an error before exit.
