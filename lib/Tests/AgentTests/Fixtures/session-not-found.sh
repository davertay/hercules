#!/bin/bash
# Reproduces the harness "session not found" signature.
# Empirical: exit 1, stderr prefix "No conversation found with session ID:",
# and a stream-json result event with subtype "error_during_execution".
echo '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["No conversation found with session ID: 00000000-0000-0000-0000-000000000000"],"session_id":"11111111-1111-1111-1111-111111111111"}'
echo "No conversation found with session ID: 00000000-0000-0000-0000-000000000000" >&2
exit 1
