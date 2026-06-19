#!/usr/bin/env bash
# Build, launch the Hercules macOS app, and capture a screenshot of its main window.
#
# Usage: screenshot.sh [output_path] [preview_target]
#   output_path     - PNG output path (default: ./tmp/hercules-screenshot.png)
#   preview_target  - optional `PreviewTarget` raw value (e.g. flowExecuteDAG,
#                     flowExecuteEmpty). When set, the app launches directly into
#                     the harness view for that target, bypassing the Launcher.
#                     Forwarded to the app via the HERCULES_PREVIEW env var.
#                     Requires a Debug build (the harness is `#if DEBUG`-gated).
#
# Exit codes:
#   0 - success
#   1 - build failed
#   2 - app bundle not found
#   3 - app failed to launch / window did not appear
#   4 - screencapture failed
#   5 - screensaver / lock screen active (screen capture would only get
#       the screensaver / lock UI, not the app window — fail fast before
#       the ~20s build/launch cycle)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$REPO_ROOT"

OUTPUT_PATH="${1:-$REPO_ROOT/tmp/hercules-screenshot.png}"
PREVIEW_TARGET="${2:-${HERCULES_PREVIEW:-}}"
mkdir -p "$(dirname "$OUTPUT_PATH")"

APP_NAME="Hercules"
APP_PROCESS="Hercules"

# Pre-flight: bail out if the screensaver is running or the screen is
# locked. The window-bounds query (System Events `position of window 1`)
# returns 0 windows for the foreground app while either of these states
# is active, even though the app actually launched fine — the
# downstream "could not locate main window" failure is indistinguishable
# from a real broken-app case, costing a ~20s build/launch cycle per
# attempt. Both checks are <50ms so we run them before `make build`.
if pgrep -x ScreenSaverEngine >/dev/null 2>&1; then
    echo "ERROR: screensaver is active. Dismiss it (move the mouse / hit a key) and retry." >&2
    exit 5
fi
# `CGSSessionScreenIsLocked` key is only present in the IOConsoleUsers
# dict when the screen is locked; `plutil -extract` returns non-zero
# when the key is absent (the unlocked case), which is what we want.
# Wrapping in `if` (with stderr suppressed only on the extract — ioreg
# is benign) so `set -e` doesn't kill the script on the unlocked path.
if LOCK_STATE=$(ioreg -n Root -d1 -a 2>/dev/null \
        | plutil -extract 'IOConsoleUsers.0.CGSSessionScreenIsLocked' raw - 2>/dev/null) \
        && [[ "$LOCK_STATE" == "true" ]]; then
    echo "ERROR: screen is locked. Unlock it and retry." >&2
    exit 5
fi

echo "==> Building $APP_NAME"
make build >/dev/null

echo "==> Resolving built .app path"
BUILT_DIR=$(xcodebuild -showBuildSettings \
    -project Hercules.xcodeproj \
    -scheme "$APP_NAME" \
    -destination 'platform=macOS,arch=arm64' 2>/dev/null \
    | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR =/ {print $2; exit}')
APP_PATH="$BUILT_DIR/$APP_NAME.app"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app bundle not found at $APP_PATH" >&2
    exit 2
fi
echo "    $APP_PATH"

echo "==> Killing any existing instance"
pkill -x "$APP_PROCESS" 2>/dev/null || true
sleep 0.5

if [[ -n "$PREVIEW_TARGET" ]]; then
    echo "==> Launching app with HERCULES_PREVIEW=$PREVIEW_TARGET"
    # `open --env VAR=VALUE` forwards env vars into the launched
    # process. The Debug build's `HerculesScene` reads the variable
    # and swaps the launcher content for the harness view. `--fresh`
    # discards persistent window state so the harness window opens
    # at its default size on every launch.
    open -F --env "HERCULES_PREVIEW=$PREVIEW_TARGET" -a "$APP_PATH"
else
    echo "==> Launching app"
    open -a "$APP_PATH"
fi

echo "==> Waiting for main window"
WINDOW_BOUNDS=""
LAST_ERR=""
for i in {1..60}; do
    sleep 0.25
    set +e
    WINDOW_BOUNDS=$(osascript \
        -e "tell application \"System Events\"" \
        -e "    if not (exists process \"$APP_PROCESS\") then return \"\"" \
        -e "    tell process \"$APP_PROCESS\"" \
        -e "        set frontmost to true" \
        -e "        if (count of windows) is 0 then return \"\"" \
        -e "        set p to position of window 1" \
        -e "        set s to size of window 1" \
        -e "        return (item 1 of p as text) & \",\" & (item 2 of p as text) & \",\" & (item 1 of s as text) & \",\" & (item 2 of s as text)" \
        -e "    end tell" \
        -e "end tell" 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 && -n "$WINDOW_BOUNDS" ]]; then break; fi
    LAST_ERR="$WINDOW_BOUNDS"
    WINDOW_BOUNDS=""
done

if [[ -z "$WINDOW_BOUNDS" ]]; then
    echo "ERROR: could not locate main window after ~15s." >&2
    echo "Last osascript output: $LAST_ERR" >&2
    echo "If the message mentions 'not allowed assistive access', enable the controlling terminal under" >&2
    echo "  System Settings > Privacy & Security > Accessibility" >&2
    exit 3
fi

# small pause to let window finish drawing
sleep 0.4

echo "==> Capturing window: $WINDOW_BOUNDS"
IFS=',' read -r X Y W H <<<"$WINDOW_BOUNDS"
if ! screencapture -x -o -t png -R "${X},${Y},${W},${H}" "$OUTPUT_PATH"; then
    echo "ERROR: screencapture failed" >&2
    exit 4
fi

echo "==> Saved: $OUTPUT_PATH"

# Optional: quit the app after capture (set HERCULES_KEEP_OPEN=1 to leave it running)
if [[ "${HERCULES_KEEP_OPEN:-0}" != "1" ]]; then
    echo "==> Quitting app"
    osascript -e "tell application \"$APP_PROCESS\" to quit" 2>/dev/null || true
fi
