#!/bin/bash
# Traps SIGTERM and ignores it; only SIGKILL (sent to this bash process) stops it.
trap '' SIGTERM
echo '{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000000","tools":[],"mcp_servers":[]}'
sleep 60
