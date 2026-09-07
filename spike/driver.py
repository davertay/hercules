#!/usr/bin/env python3
"""Driver: spawn claude in stream-json mode, send one user line, keep stdin OPEN.

Usage: driver.py <session-id> [extra claude args...]
Never writes the answer file.

Paths default to the original /tmp/spike layout; env vars allow a second
concurrent run to use its own files.
"""
import json, os, subprocess, sys, time

SPIKE = os.environ.get("SPIKE_DIR", "/tmp/spike")
STDOUT_LOG = os.environ.get("SPIKE_STDOUT_LOG", os.path.join(SPIKE, "stdout.log"))
STDERR_LOG = os.environ.get("SPIKE_STDERR_LOG", os.path.join(SPIKE, "stderr.log"))
MCP_CONFIG = os.environ.get("SPIKE_MCP_CONFIG", os.path.join(SPIKE, "mcp.json"))
STEER_FILE = os.environ.get("SPIKE_STEER", os.path.join(SPIKE, "steer.md"))
MCP_TOOL   = os.environ.get("SPIKE_MCP_TOOL", "mcp__spike__ask_user")

if len(sys.argv) < 2:
    sys.stderr.write("usage: driver.py <session-id> [extra claude args...]\n")
    sys.exit(2)

session_id = sys.argv[1]
extra = sys.argv[2:]

cmd = [
    "claude", "--print",
    "--output-format", "stream-json",
    "--input-format", "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--permission-mode", "default",
    "--setting-sources", "user",
    "--allowedTools", "Read", "Grep", "Glob", MCP_TOOL,
    "--session-id", session_id,
]
if not os.environ.get("SPIKE_OMIT_MCP"):
    cmd[-2:-2] = ["--mcp-config", MCP_CONFIG]
if not os.environ.get("SPIKE_OMIT_STEER"):
    cmd[-2:-2] = ["--append-system-prompt-file", STEER_FILE]
cmd += extra

PROMPT = os.environ.get("SPIKE_PROMPT",
          "I need to add a caching layer to my app. Ask me exactly one "
          "multiple-choice question about which cache backend I should use, "
          "then wait for my answer before doing anything else.")

out = open(STDOUT_LOG, "a", buffering=1)
err = open(STDERR_LOG, "a", buffering=1)

t0 = time.time()

def w(msg):
    out.write("%6.1fs | %s\n" % (time.time() - t0, msg))

w("DRIVER START pid=%d wall=%s" % (os.getpid(), time.strftime("%H:%M:%S")))
w("CMD %s" % " ".join(cmd))
ccenv = {k: v for k, v in os.environ.items() if k.startswith("CLAUDE_CODE_")}
w("ENV CLAUDE_CODE_* = %s" % (json.dumps(ccenv, sort_keys=True) if ccenv else "{} (none set)"))

p = subprocess.Popen(
    cmd,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=err,
    text=True,
    bufsize=1,
    cwd=SPIKE,
)

line = json.dumps({"type": "user", "message": {"role": "user", "content": PROMPT}})
p.stdin.write(line + "\n")
p.stdin.flush()
w("STDIN WROTE 1 line, stdin left OPEN")

try:
    for out_line in p.stdout:
        w(out_line.rstrip("\n"))
except Exception as e:  # noqa: BLE001
    w("DRIVER READ EXCEPTION %r" % (e,))

rc = p.wait()
total = time.time() - t0
w("EXIT code=%s total_elapsed=%.1fs wall=%s" % (rc, total, time.strftime("%H:%M:%S")))
out.flush()
print("exit code: %s" % rc)
print("total elapsed: %.1fs" % total)
