#!/usr/bin/env python3
"""Run one spike experiment end-to-end, then print a structured summary.

usage: run_spike.py <label> <workdir> <answer|-> <followup|-> <timeout_s> [extra claude args...]

Answers the blocking MCP tool when it blocks (if an answer is given), waits for
the final `result` line, kills the driver + server, then reports.
"""
import json, os, subprocess, sys, time, uuid, signal

label, wd, answer, followup, tmo = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
extra = sys.argv[6:]
if answer == "-": answer = ""
if followup == "-": followup = ""

os.makedirs(wd, exist_ok=True)
P = lambda n: os.path.join(wd, n)
for f in ("stdout.log", "stderr.log", "server.log", "answer.txt"):
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

t0 = time.time()
p = subprocess.Popen(["python3", "/tmp/spike/driver.py", sid] + extra, env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

answers_written = 0
while time.time() - t0 < tmo:
    so = open(P("stdout.log")).read()
    if '"type":"result"' in so:
        break
    if answer:
        sl = open(P("server.log")).read()
        blocks = sl.count("TOOLCALL BLOCKING START")
        if blocks > answers_written:
            time.sleep(3)  # let server.py finish its remove() first
            txt = answer if answers_written == 0 else (followup or answer)
            open(P("answer.txt"), "w").write(txt)
            answers_written += 1
    time.sleep(0.5)

elapsed = time.time() - t0
try: p.terminate()
except Exception: pass
sl = open(P("server.log")).read()
for line in sl.splitlines():
    if "SERVER START pid=" in line:
        try: os.kill(int(line.split("pid=")[1].split()[0]), signal.SIGTERM)
        except Exception: pass

# ---------- analysis ----------
print("=" * 78)
print("%s   session=%s   wall=%.1fs   answers_written=%d" % (label, sid, elapsed, answers_written))
print("args: %s" % (" ".join(extra) if extra else "(none)"))
print("=" * 78)

order, res = [], None
for raw in open(P("stdout.log")):
    ts, _, rest = raw.partition("| ")
    rest = rest.strip()
    if not rest.startswith("{"): continue
    try: o = json.loads(rest)
    except Exception: continue
    t = o.get("type")
    if t == "assistant":
        for c in o.get("message", {}).get("content", []):
            if isinstance(c, dict) and c.get("type") == "tool_use":
                q = c.get("input", {}).get("query") if c.get("name") == "ToolSearch" else None
                order.append(("TOOL_USE", ts.strip(), c.get("name"), c.get("id"), q))
            elif isinstance(c, dict) and c.get("type") == "text" and c.get("text", "").strip():
                order.append(("TEXT", ts.strip(), c["text"], None, None))
    elif t == "user":
        for c in o.get("message", {}).get("content", []):
            if isinstance(c, dict) and c.get("type") == "tool_result":
                order.append(("TOOL_RESULT", ts.strip(), c.get("tool_use_id"), c.get("is_error"), c.get("content")))
    elif t == "result":
        res = o

print("--- ordered events ---")
for e in order:
    if e[0] == "TOOL_USE":
        print("%8s  TOOL_USE      %-28s id=%s%s" % (e[1], e[2], e[3], ("  query=%r" % e[4]) if e[4] else ""))
    elif e[0] == "TOOL_RESULT":
        body = e[4] if isinstance(e[4], str) else json.dumps(e[4])
        print("%8s  TOOL_RESULT   id=%s is_error=%r" % (e[1], e[2], e[3]))
        print("            content: %s" % (body[:600] if body else body))
    else:
        print("%8s  TEXT: %s" % (e[1], e[2][:600]))

qtools = [e[2] for e in order if e[0] == "TOOL_USE" and e[2] in ("AskUserQuestion", "mcp__spike__ask_user")]
print()
print("FIRST question-tool called: %s" % (qtools[0] if qtools else "NONE"))
print("all question-tool calls   : %s" % (qtools or "[]"))
print("all tool_use names        : %s" % [e[2] for e in order if e[0] == "TOOL_USE"])
print()
if res:
    print("RESULT  subtype=%r  is_error=%r  stop_reason=%r  terminal_reason=%r  num_turns=%r  duration_ms=%r"
          % (res.get("subtype"), res.get("is_error"), res.get("stop_reason"),
             res.get("terminal_reason"), res.get("num_turns"), res.get("duration_ms")))
    print("permission_denials: %s" % json.dumps(res.get("permission_denials")))
    print("result text:"); print(res.get("result"))
else:
    print("RESULT: *** no result line (timed out at %.0fs) ***" % tmo)
print("stderr bytes: %d" % os.path.getsize(P("stderr.log")))
