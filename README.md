# Hercules

Agentic Coworking for macOS

Hercules is a system of agent-centric building that implements this workflow:
Design -> Requirements -> Allocation -> Implementation -> Review

**Design** - figure out _what_ to build
**Requirements** - derive _how_ to build
**Allocation** - divide into agent-capable units of work
**Implementation** - drive the coding swarm
**Review** - quality gate refinement

This flow of agentic-driven coding works very well when performed manually by an experienced developer. It is this dance of many dozens of chat session that Hercules automates.

## Philosophy

You do the design, AI builds everything, and you review/approve before shipping.

The design part is expected to be _hard_, deeply engaging, and mentally taxing. If you find that it is not, you might be some kind of wizard, or more likely fell into the trap of delegating the thinking to the agent. If the task doesn't require your, and others, considered input consider replacing yourself with a small shell script.

### The Premise

Agent harnesses, given enough detail, are more than capable of building a small slice of a software product. Getting them to do so _well_ and _consistently_ is tricky.

### The Problem

Providing "enough detail" to realize the developers vision is on the order of the same amount of work as just writing the code directly.

As of the time of writing (Jan 2026), models are barely good enough at detailed work. They are solid for web apps, but write poor quality code in many other domains. I do not know why, and can only guess that training data is the primary influence. The code produced often uses out-of-date patterns from older toolchains and is not well written at the function body level.

Hercules is an automation workflow designed to mitigate these deficiencies in three ways:
1. gather and derive micro detail efficiently
2. slice the work into chunks that do not overwhelm LLM contexts
3. drive a quality outcome through focused iteration

### Nail the Design

We always start with figuring out what to build. Be it a bug fix, feature, new system, the process always begins here.

_**This is the single most critical piece of the entire system.**_ A small mistake, a wrong choice, an omission will be amplified in the output. This to be expected and is not a surprise due to unknown unknowns. It is also why we tend towards a ship-and-iterate style.

The difference is that when humans are writing the code and an unknown is encountered, they will use judgement and incorporate knowledge that was not captured in the design to resolve the issue. An automated system cannot reach beyond what is in the design. Even if it could, it would not know enough to do so, _because_ the unknown is not written down.

So our goal is to spend all our energy to get the design as close to perfect as possible. The effort that would normally be spread across up-front design, requirements gathering, and figure-it-out-as-you-code _must_ be done up front.

### Automate Automate Automate

If we accept that the design fully captures the idea and scope of what to build, what not to build, and embodies all constraints, assumptions and decisions, then the path to shippable code can be mechanized. If there are mistakes in the design they will also ship and so be it. Open a new issue and start the process over to address deficiencies.

Producing requirements becomes a technical task of translating the _what to build_ into the _how to build_ by ingesting specifications, researching optimal algorithms, and understanding the existing codebase. Agents are very good at this.

We cannot (yet) throw a large and deep requirements doc at an agent and expect a good result. But an agent can automate the task of breaking the work down into individual, verifiable pieces that are within reach. As agents improve those pieces can become larger.

Once we have the units of work the easy part of churning out code begins. The tickets form a dependency graph which dictate the sequencing and parallelization. Test driven development cycles ensure correct outcomes.

Completed code can be revised and polished by automated review personas. This is the chance to scrutinize for security holes, weed out anti-patterns and attempt to lift the quality in general. The tests generally follow the user-stories from the requirements, therefore we can lean on all tests being satisfied as proof that the code is "correct" _as per design_. Again, nailing the design is key.

### Human Quality Gate

Once pull requests are open for review, tests are passing, and automated review issues have been addressed, we have the opportunity for the human-in-the-loop to have the final say.

This is the point where you look at the code and realize what you did wrong in the design phase. The choice is yours to hammer out some refinements or just ship it aleady.

## Agent Compatibility

Agents are orchestrated by invoking the vendor specific CLI harness. Right now we only support Claude Code.

## Ticketing

Units of work are expressed as Kanban board style tickets. They include requirements, acceptance critera, and blockers.

Compatbile ticketing systems will be added but right now we only support GitHub issues.

## Credits

Many thanks to a lot of folks as we all figure out new ways of building software. Special shout out to @mattpocock for helping clarify many of these ideas, especially the `grill-me` skill which is the cornerstone of collaborative agentic design sessions.

