#!/bin/bash
# Writes the arguments it was launched with into its working directory — the Turn's worktree, which the
# test owns — so a test can assert on the invocation Hercules rendered without reaching into a Session's
# scratch for it. The appended system prompt is copied out beside them, because the file its argument
# names is Turn scratch that is gone once the Turn returns; like the real Harness, the last one given is
# the one kept. Then finishes like a Turn that had nothing to say.
printf '%s\n' "$@" > harness-args.txt
rm -f harness-system-prompt.md
while [ $# -gt 0 ]; do
    if [ "$1" = "--append-system-prompt-file" ]; then
        cp "$2" harness-system-prompt.md
    fi
    shift
done
echo '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"result":"ok"}'
