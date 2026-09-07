#!/usr/bin/env python3
import json, os, sys, time

LOG = open(os.environ.get("SPIKE_LOG", "/tmp/spike/server.log"), "a", buffering=1)
ANSWER = os.environ.get("SPIKE_ANSWER_FILE", "/tmp/spike/answer.txt")

def log(m):
    LOG.write("%.3f %s %s\n" % (time.time(), time.strftime("%H:%M:%S"), m))

def send(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

TOOL = {
  "name": "ask_user",
  "description": "Ask the user a question and wait for their answer. Use this whenever you need to ask the user anything.",
  "inputSchema": {"type":"object",
    "properties":{"questions":{"type":"array","items":{"type":"object"}}},
    "required":["questions"]}
}

log("SERVER START pid=%d" % os.getpid())
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: msg = json.loads(line)
    except Exception: log("BADLINE %r" % line); continue
    method = msg.get("method")
    log("RECV method=%s id=%s params=%s" % (method, msg.get("id"), json.dumps(msg.get("params"))[:3000]))
    if method == "initialize":
        send({"jsonrpc":"2.0","id":msg["id"],"result":{
            "protocolVersion": msg.get("params",{}).get("protocolVersion","2025-06-18"),
            "capabilities":{"tools":{}},
            "serverInfo":{"name":"spike","version":"0.1.0"}}})
    elif method == "tools/list":
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"tools":[TOOL]}})
    elif method == "tools/call":
        log("TOOLCALL BLOCKING START")
        if os.path.exists(ANSWER): os.remove(ANSWER)
        while not os.path.exists(ANSWER): time.sleep(0.2)
        answer = open(ANSWER).read().strip()
        log("TOOLCALL UNBLOCKED answer=%r" % answer)
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"content":[{"type":"text","text":answer}]}})
    elif method and method.startswith("notifications/"):
        pass
    elif "id" in msg:
        send({"jsonrpc":"2.0","id":msg["id"],"error":{"code":-32601,"message":"unknown %s" % method}})
