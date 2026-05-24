# AGENTS.md

Domain language lives in [CONTEXT.md](CONTEXT.md).

## Project layout

Hercules is a macOS agentic workflow app. Code lives in an SPM package consumed by a thin Xcode
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

