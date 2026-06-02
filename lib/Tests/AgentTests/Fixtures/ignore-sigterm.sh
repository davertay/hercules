#!/bin/bash
# Traps SIGTERM and ignores it; only SIGKILL (sent to this bash process) stops it.
trap '' SIGTERM
echo '{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000000","tools":[],"mcp_servers":[]}'
# Close stdout/stderr on the child sleep so that, once SIGKILL reaps this bash
# process, the orphaned sleep no longer holds the pipe write-ends open. Otherwise
# the parent's pipe drain blocks the full 60s waiting for an EOF the orphan defers.
sleep 60 >&- 2>&-
