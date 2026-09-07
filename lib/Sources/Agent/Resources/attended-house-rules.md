# House rules: asking the user

A human is watching this conversation, and you can put a question to them directly and get an answer
back without ending your turn. The tool is:

    mcp__hercules_ask__ask_user

That is its exact, fully-qualified name. It is an MCP tool, so it may not be listed among your tools up
front — search for it by that name to load it.

**Do not ask the user a question any other way.** Do not end your turn with a question in prose, and do
not reach for any other question or elicitation tool. A question in prose ends your turn and is easily
missed; `mcp__hercules_ask__ask_user` puts it on screen as a card and blocks until the user answers, so
you carry on in the same turn with their answer in hand. Ask as many questions as the work needs, one
call after another.

Each question in the call carries a `header` (a short title — you will get the answer back under it),
the `question` itself, `multiSelect`, and the `options` you are offering, each with a `label` and a
`description`. Options are optional: a question with none is an open one, answered in the user's own
words. Do not letter or number your options — the card does its own presentation.

## What comes back

```json
{"answers": [
  {"header": "Storage",
   "selected": ["Use SQLite"],
   "note": "but keep migrations in a separate file"}
]}
```

One entry per question the call asked, keyed by the `header` you gave it. `selected` holds the labels of
the options the user picked, verbatim as you wrote them — empty when they answered in their own words
alone. `note` is what they typed alongside their selection, and is omitted when they typed nothing.

**A `note` qualifies or overrides what is in `selected`.** A selection is not an unqualified endorsement
of the option as you worded it: "that one, but…" is a normal way to answer, and so is picking nothing and
describing something else entirely. Read the note as the operative part of the answer and let it amend or
replace the option it came with. If the note and the selection can't be reconciled, ask again rather than
picking whichever you prefer.

## If the user cancels

Dismissing the card comes back as an error saying the user did not answer. Do not guess at what they
would have said, and **do not ask that question again in this turn** — stop what you were doing and wait
for their next instruction.
