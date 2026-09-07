#!/usr/bin/env python3
"""E-series: does an open-ended design brief route through the MCP ask tool or prose?

usage: run_e.py <label> <workdir> <timeout_s>
"""
import json, os, subprocess, sys, time, uuid, signal

label, wd, tmo = sys.argv[1], sys.argv[2], float(sys.argv[3])

SERVER   = "hercules_ask"
MCP_TOOL = "mcp__hercules_ask__ask_user"
PROMPT   = ("I want to add offline support to my note-taking app. Interview me about "
            "the design one question at a time before proposing anything.")
ANSWERS  = [
    "React Native, iOS and Android. A few thousand notes per user.",
    "Conflicts are rare but must never lose data - I'd rather keep both versions than overwrite.",
    "That's enough for now. Stop asking questions and just give me a one-sentence summary.",
]

os.makedirs(wd, exist_ok=True)
P = lambda n: os.path.join(wd, n)
for f in ("stdout.log", "stderr.log", "server.log", "answer.txt", "driver.out"):
    if os.path.exists(P(f)): os.remove(P(f))
for f in ("stdout.log", "stderr.log", "server.log"):
    open(P(f), "w").close()

sid = str(uuid.uuid4())
open(P("session-id.txt"), "w").write(sid + "\n")
json.dump({"mcpServers": {SERVER: {"command": "python3", "args": ["/tmp/spike/server.py"],
          "env": {"SPIKE_LOG": P("server.log"), "SPIKE_ANSWER_FILE": P("answer.txt")}}}},
          open(P("mcp.json"), "w"))

env = dict(os.environ)
env.update({"SPIKE_STDOUT_LOG": P("stdout.log"), "SPIKE_STDERR_LOG": P("stderr.log"),
            "SPIKE_MCP_CONFIG": P("mcp.json"), "SPIKE_MCP_TOOL": MCP_TOOL,
            "SPIKE_PROMPT": PROMPT})

t0 = time.time()
p = subprocess.Popen(["python3", "/tmp/spike/driver.py", sid], env=env,
                     stdout=open(P("driver.out"), "w"), stderr=subprocess.STDOUT,
                     start_new_session=True)
answered = 0
while time.time() - t0 < tmo:
    if '"type":"result"' in open(P("stdout.log")).read(): break
    sl = open(P("server.log")).read()
    if sl.count("TOOLCALL BLOCKING START") > answered and answered < len(ANSWERS):
        time.sleep(3)
        open(P("answer.txt"), "w").write(ANSWERS[answered]); answered += 1
    time.sleep(0.5)
elapsed = time.time() - t0

try: p.terminate()
except Exception: pass
for line in open(P("server.log")):
    if "SERVER START pid=" in line:
        try: os.kill(int(line.split("pid=")[1].split()[0]), signal.SIGTERM)
        except Exception: pass

# ---- analysis ----
seq, res, first = [], None, None
for raw in open(P("stdout.log")):
    ts, _, rest = raw.partition("| "); rest = rest.strip()
    if not rest.startswith("{"): continue
    try: o = json.loads(rest)
    except Exception: continue
    if o.get("type") == "assistant":
        for c in o.get("message", {}).get("content", []):
            if not isinstance(c, dict): continue
            if c.get("type") == "tool_use":
                seq.append((ts.strip(), "tool_use", c.get("name")))
                if first is None: first = ("tool_use", c.get("name"), json.dumps(c.get("input"))[:110])
            elif c.get("type") == "text" and c.get("text", "").strip():
                seq.append((ts.strip(), "text", c["text"][:90].replace("\n", " ")))
                if first is None: first = ("text", None, c["text"][:300].replace("\n", " "))
    elif o.get("type") == "result":
        res = o

names = [s[2] for s in seq if s[1] == "tool_use"]
used = MCP_TOOL in names
verdict = "ASKED_VIA_TOOL" if used else ("ASKED_IN_PROSE" if res else "INCOMPLETE")

print("=" * 74)
print("%s  session=%s  wall=%.1fs  answers_given=%d" % (label, sid, elapsed, answered))
print("=" * 74)
print("first assistant action : %s" % (("%s %s  %s" % (first[0], first[1] or "", first[2])) if first else "NONE"))
print("tool_use sequence      : %s" % names)
print("used %s : %s" % (MCP_TOOL, used))
print("VERDICT                : %s" % verdict)
if res:
    print("result  subtype=%r is_error=%r stop_reason=%r num_turns=%r"
          % (res.get("subtype"), res.get("is_error"), res.get("stop_reason"), res.get("num_turns")))
print("\n--- first 6 assistant events ---")
for ts, kind, val in seq[:6]:
    print("  %8s %-9s %s" % (ts, kind, val))
