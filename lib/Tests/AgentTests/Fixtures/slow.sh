#!/bin/bash
# Emits a minimal init event then sleeps, giving the test time to cancel.
echo '{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000000","tools":[],"mcp_servers":[]}'
exec sleep 30
