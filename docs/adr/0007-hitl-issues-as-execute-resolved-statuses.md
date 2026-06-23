# Human-gated Issues as Execute-resolved statuses

Some Issues need an explicit human decision before they can move: a **Proposed Issue** a Validate
**Persona** recommends as a fix, and (later) a manual **Gate** carved out in Allocate for work an
Agent can't do. We model both as ordinary `issue` rows in extra `status` values — `proposed` now,
a manual/`gate` status later — rather than a separate approvals table or queue. The Execute run
loop already only auto-picks `status == "new"`, so these statuses are inert to it by construction;
the human resolves them from the **Execute** DAG with a positive control and a negative one, and the
negative always soft-deletes (`isDeleted = true`), matching `clearIssues`.

The two HITL statuses are kept distinct rather than unified under one status plus an `origin`
discriminator, because their positive transition and graph role genuinely differ: approving a
Proposed Issue sets it to `new` (the Agent then implements it) and it never has dependencies, whereas
marking a Gate done sets it straight to `done` (the Agent never runs it) and a Gate **can be depended
upon**, gating its downstream Issues. One status with a discriminator would still need branching
logic for the positive action and the dependency semantics — more moving parts than two status
values, which the DAG can already colour and the run loop already ignores.

## Considered Options

- **Dedicated approvals table / queue** — rejected: duplicates the Issue's identity, body, and
  dependency edges, and forces the Execute DAG to union two sources to show one graph. The Issue row
  already carries everything; an approval is just a status it's waiting in.
- **One `pending-human` status + `origin` field** — rejected: the positive action (`new` vs `done`)
  and dependency role differ enough that the discriminator buys nothing over two plain statuses.

## Consequences

- Resolving HITL Issues lives in the Execute Phase UI, not Validate — a Persona proposes from
  Validate, but approve/deny happens on the Execute DAG, so the user ping-pongs Validate → Execute →
  Validate. Accepted for the MVP; an inline action may revisit it later.
- Re-running a Persona may re-propose a previously denied (soft-deleted) fix; the user denies it
  again. Accepted for now.
