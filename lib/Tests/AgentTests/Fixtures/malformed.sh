#!/bin/bash
# Emits a malformed line, then a valid passthrough line, and exits cleanly.
echo 'not valid json here'
echo '{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000000","tools":[],"mcp_servers":[]}'
