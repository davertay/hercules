#!/bin/bash
# Writes the arguments it was launched with into its working directory — the Turn's worktree, which the
# test owns — so a test can assert on the invocation Hercules rendered without reaching into a Session's
# scratch for it. Then finishes like a Turn that had nothing to say.
printf '%s\n' "$@" > harness-args.txt
echo '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"result":"ok"}'
