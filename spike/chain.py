import json, sys
lines=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
DANGLE_MSG_UUID = sys.argv[2]
DANGLE_TOOL_ID  = sys.argv[3]
LEAF            = sys.argv[4] if len(sys.argv) > 4 else None
by_uuid = {}
for i,o in enumerate(lines):
    if o.get("uuid") and o["uuid"] not in by_uuid: by_uuid[o["uuid"]]=(i+1,o)

print("1) tool_result ever written for the dangling tool_use %s?" % DANGLE_TOOL_ID)
found=[o for o in lines for c in ((o.get("message") or {}).get("content") or [])
       if isinstance(c,dict) and c.get("type")=="tool_result" and c.get("tool_use_id")==DANGLE_TOOL_ID]
print("   ->", "YES" if found else "NO - never written")

print("\n2) does any entry claim the dangling assistant message as parent?")
kids=[(i+1,o["type"]) for i,o in enumerate(lines) if o.get("parentUuid")==DANGLE_MSG_UUID]
print("   ->", kids if kids else "0 children - ORPHANED")

print("\n3) where does the post-resume branch attach instead?")
for o in lines:
    if o.get("isMeta") and o.get("type")=="user":
        p=o.get("parentUuid")
        print("   synthetic user text : %r" % o["message"]["content"][0]["text"])
        print("   parentUuid          : %s" % p)
        if p in by_uuid:
            idx,pt=by_uuid[p]
            print("   -> entry %d, type=%s, attachment=%s" % (idx, pt.get("type"), (pt.get("attachment") or {}).get("type")))
if DANGLE_MSG_UUID in by_uuid:
    print("   (dangling assistant message is entry %d)" % by_uuid[DANGLE_MSG_UUID][0])

if LEAF:
    print("\n4) parent chain of the final answer, walking back (cycle-guarded):")
    cur, seen, chain = LEAF, set(), []
    while cur and cur in by_uuid and cur not in seen and len(chain) < 100:
        seen.add(cur); idx,o = by_uuid[cur]
        chain.append("e%d:%s" % (idx, o.get("type")))
        cur = o.get("parentUuid")
    print("   " + " <- ".join(chain))
    print("   chain includes dangling entry? ->",
          ("e%d:" % by_uuid[DANGLE_MSG_UUID][0]) in " ".join(chain) if DANGLE_MSG_UUID in by_uuid else "n/a")
