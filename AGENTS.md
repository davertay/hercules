# AGENTS.md

Domain language lives in [CONTEXT.md](CONTEXT.md).

## Project layout

Hercules is a macOS agentic coworking app. Code lives in an SPM package consumed by a thin Xcode
app target — all logic lives in the package modules.

- `Hercules.xcodeproj` — the Xcode project.
- `Hercules/` — root-level wrapper code and assets (the Xcode app target).
- `lib/` — feature and module library (SPM package).

Toolchain: Swift 6.0. Platforms: iOS 18+, macOS 15+, visionOS 2+.

## Commands

Use the Makefile in the root folder.

```bash
make build        # Build the entire project
make test         # Run all tests
```

## When implementing an issue

1. Read the issue body in full — it's the spec.
2. Read [CONTEXT.md](CONTEXT.md) for domain terms relevant to the change.
3. Read [ISSUES.md](ISSUES.md) for GitHub workflow mechanics (labels, branches, PRs, status comments).
4. Locate the smallest surface area that needs to change. Prefer editing
   existing files to creating new ones.
5. Match the surrounding style; don't refactor unrelated code.
6. Add or update tests next to the existing test files for the module you're
   changing.
7. Build and test locally is not available; rely on CI. Make small,
   well-reasoned changes per commit so CI failure logs point at the right
   place.
8. Note any assumptions made (about acceptance criteria, edge cases, library
   APIs you couldn't verify) in the PR body's `## Assumptions made` section.

### Out of scope

- Don't add features, refactor, or introduce abstractions beyond what the
  issue requires.
- Don't add error handling, fallbacks, or validation for scenarios that can't
  happen.
- Don't bypass safety checks (`--no-verify`, `--no-gpg-sign`, etc.) to make
  hooks pass — fix the underlying issue.
- Don't amend, squash, or force-push. Incremental commits only.

