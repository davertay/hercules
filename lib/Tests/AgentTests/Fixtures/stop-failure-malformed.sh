#!/bin/bash
# As stop-failure.sh, but the drop-file it leaves isn't JSON — a hook killed mid-write, a payload shape
# that changed under us. The Turn must fail as though no hook had run at all.
settings=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--settings" ]; then settings="$arg"; break; fi
  prev="$arg"
done

hook=$(sed -n 's/.*"command":"\([^"]*\)".*/\1/p' "$settings")
echo '{"hook_event_name":"StopFailure","reas' | eval "$hook"

echo '{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":1,"result":"You'"'"'ve hit your session limit · resets 11pm (UTC)"}'
exit 1
