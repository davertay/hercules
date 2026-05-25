# Per-Turn Harness invocation

The Agent module spawns a fresh `claude` subprocess for **every Turn** rather than running one
long-lived process per Session. The session ID is the durable handle that bridges Turns: each
Turn after the first uses `--resume <session-id>`. The process exits at the end of the
assistant turn; there is no in-memory state to keep alive between Turns.

## Why

The alternative — one long-lived `claude` process per Session with stream-json input/output —
is a strict superset in raw capability but a poor fit for our actual needs:

- **App-restart resilience falls out for free.** With per-Turn invocations, no in-memory state
  outlives the app; resume is the same code path as the very first send. A long-lived process
  would have to re-establish itself on every app launch anyway, so the long-lived model gets the
  cost without the benefit.
- **Turn boundaries are unambiguous.** Process exit ends the Turn. With long-lived processes,
  end-of-turn must be inferred from stream-json terminator events, and cancellation of a single
  Turn (vs the whole Session) has no clean primitive.
- **Concurrent Turns on the same Session are impossible by construction.** Claude won't let two
  processes share session storage, which matches the semantics we want; long-lived would require
  building our own turn queue or rejection logic.
- **Token spend is equivalent.** Anthropic's prompt caching is keyed by byte-exact prefix and
  lives server-side; a fresh process that reconstructs the same prefix hits the cache the same
  way the long-lived process would. The model is stateless either way — long-lived processes
  hide the re-send from us but still pay it on the wire.

The cost we accept is ~1–2 s of Harness bootstrap latency per Turn. For a chat UX where the user
spends longer reading the response than waiting for the next Turn to start, this is acceptable.
If profiling ever shows this is unacceptable for a specific flow, the long-lived model can be
introduced behind the same `AgentClient` API without breaking callers.
