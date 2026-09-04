#!/bin/bash
# Stands in for the StopFailure hook, which a fake harness can never fire for real. We pull the hook's
# own command out of the --settings file we were handed and run it with the event payload on stdin,
# exactly as the real harness runs a shell-form hook — so the path under test is the one Hercules
# generated, not one the test invented. Then we fail the way the harness fails on an API error: an
# is_error result on stdout carrying its wording, and a non-zero exit with empty stderr.
settings=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--settings" ]; then settings="$arg"; break; fi
  prev="$arg"
done

hook=$(sed -n 's/.*"command":"\([^"]*\)".*/\1/p' "$settings")
echo '{"session_id":"00000000-0000-0000-0000-000000000000","hook_event_name":"StopFailure","reason":"rate_limit"}' | eval "$hook"

echo '{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":1,"result":"You'"'"'ve hit your session limit · resets 11pm (UTC)"}'
exit 1
