#!/usr/bin/env python3
"""Launch a spike run, wait until the MCP tool blocks, print the process tree. Kills nothing."""
import json, os, subprocess, sys, time, uuid

wd = sys.argv[1]
maxwait = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0

os.makedirs(wd, exist_ok=True)
P = lambda n: os.path.join(wd, n)
for f in ("stdout.log", "stderr.log", "server.log", "answer.txt", "driver.out"):
    if os.path.exists(P(f)): os.remove(P(f))
for f in ("stdout.log", "stderr.log", "server.log"):
    open(P(f), "w").close()

sid = str(uuid.uuid4())
open(P("session-id.txt"), "w").write(sid + "\n")
json.dump({"mcpServers": {"spike": {"command": "python3", "args": ["/tmp/spike/server.py"],
          "env": {"SPIKE_LOG": P("server.log"), "SPIKE_ANSWER_FILE": P("answer.txt")}}}},
          open(P("mcp.json"), "w"))

env = dict(os.environ)
env["SPIKE_STDOUT_LOG"] = P("stdout.log")
env["SPIKE_STDERR_LOG"] = P("stderr.log")
env["SPIKE_MCP_CONFIG"] = P("mcp.json")

p = subprocess.Popen(["python3", "/tmp/spike/driver.py", sid], env=env,
                     stdout=open(P("driver.out"), "w"), stderr=subprocess.STDOUT,
                     start_new_session=True)
print("SESSION_UUID=%s" % sid)
print("DRIVER_PID=%d" % p.pid)

t0 = time.time()
while time.time() - t0 < maxwait:
    if "TOOLCALL BLOCKING START" in open(P("server.log")).read():
        break
    time.sleep(0.3)
else:
    print("TIMEOUT waiting for TOOLCALL BLOCKING START")
    sys.exit(1)

print("BLOCKED_AT=%.1fs" % (time.time() - t0))
srv = None
for line in open(P("server.log")):
    if "SERVER START pid=" in line:
        srv = int(line.split("pid=")[1].split()[0])
print("SERVER_PID=%s" % srv)
kids = subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split()
print("CLAUDE_PID=%s" % (kids[0] if kids else "?"))
