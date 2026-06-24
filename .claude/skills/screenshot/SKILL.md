---
name: screenshot
description: Build the Hercules macOS app, launch it locally, and capture a PNG screenshot of its main window. Use when the user asks to run, launch, or open the app, see what it looks like, capture a screenshot, smoke-test the UI, or verify a visual change especially during development and unit testing. Supports a preview-target mode that bypasses the Launcher and renders an in-development view directly (e.g. the Execute step's DAG view) — see the "Preview targets" section.
---

# Screenshot — Hercules

Builds the `Hercules` SwiftUI macOS app via `make build`, launches it from its DerivedData product, captures the main window, and saves it as a PNG.

## Quick start

From the repo root:

```bash
.claude/skills/screenshot/scripts/screenshot.sh
```

Default output: `tmp/hercules-screenshot.png` (relative to repo root).

To override the output path:

```bash
.claude/skills/screenshot/scripts/screenshot.sh /tmp/my-shot.png
```

After running, inspect the result by reading the PNG with the Read tool, e.g.
`Read tmp/hercules-screenshot.png`.

## Preview targets

By default the script captures the Launcher window (the app's actual entry point). For most in-development UI work the Launcher is unhelpful — you want to see the screen you're working on. Pass a `PreviewTarget` raw value as the **second** argument (or set `HERCULES_PREVIEW`) and the app launches directly into a harness view for that target, with seeded fixture data and no Launcher chrome.

```bash
.claude/skills/screenshot/scripts/screenshot.sh \
    tmp/execute-dag.png \
    flowExecuteDAG
```

See `hercules/lib/Sources/HerculesApp/PreviewHarness.swift` for the canonical list.

The harness is **debug-only**: the fixture seeders are gated by `#if DEBUG` in the `HerculesApp` module, so Release builds ship no usable harness code. Re-run `make build` (Debug is the default) to pick up any new targets you add.

To add a new target: extend the `PreviewTarget` enum and the `PreviewHarnessView` switch in `hercules/lib/Sources/HerculesApp/PreviewHarness.swift`, lift any required fixture seeders from the corresponding `#Preview` block to a `public` `#if DEBUG`-gated helper in the feature module (see `seedExecuteDAGPreviewTickets(at:)` in `ExecuteStepView.swift` for the canonical shape), and add an entry to the table above.

## What the script does

1. `make build` (xcodebuild, no code signing)
2. Resolves the built `.app` via `xcodebuild -showBuildSettings`
3. Kills any prior instance, then `open -a` the bundle (with `--env HERCULES_PREVIEW=…` when a target is supplied)
4. Polls `System Events` (AppleScript) for `process "Hercules"` window 1
5. Reads window position + size, calls `screencapture -x -o -R x,y,w,h`
6. Quits the app (override with `HERCULES_KEEP_OPEN=1`)

## Prerequisites (one-time)

The script reads window bounds via AppleScript / System Events. macOS will prompt the controlling terminal (e.g. iTerm, Terminal, Cursor) for **Accessibility** permission on the first run:

System Settings → Privacy & Security → Accessibility → enable the terminal app.

Without this, the script exits with code `3` ("could not locate main window").

## Options

| Variable / arg | Effect |
|---|---|
| `$1` | Output PNG path (default `tmp/hercules-screenshot.png`) |
| `$2` / `HERCULES_PREVIEW` | Preview target raw value (e.g. `flowExecuteDAG`). Bypasses the Launcher and renders the harness view for that target. See "Preview targets" above. |
| `HERCULES_KEEP_OPEN=1` | Leave the app running after capture |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Build failed (propagated from `make build`) |
| 2 | Built `.app` bundle not found |
| 3 | App did not launch or window not detected (check Accessibility) |
| 4 | `screencapture` failed |
| 5 | Screensaver active or screen locked — bails before the ~20s build/launch cycle (System Events returns 0 windows for the foreground app while either is active, so a downstream window-detection failure would be indistinguishable from a real broken-app case). Dismiss the screensaver / unlock the screen and retry. |

## Notes

- Captures **only the app's main window**, not the full screen, using bounds from `System Events` and `screencapture -R`.
- `-x` suppresses the capture sound; `-o` omits the window shadow.
- App identifiers used: target `hercules`, bundle id `com.kerador.hercules`, process name `hercules`.
