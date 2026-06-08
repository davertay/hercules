#!/bin/bash
# Models a question turn over the realtime stream-json protocol. We emit the assistant tool_use
# (AskUserQuestion), the auto-error tool_result, and the result line; the harness delivers them live
# and reacts. Meanwhile stdin stays open and we drain it to a capture file, so the test can assert the
# harness actually wrote the interrupt back. When the harness finishes the turn it closes our stdin,
# the `cat` below reaches EOF and exits, and our stdout closes — letting the harness's drain end.
CAP="${AUQ_STDIN_CAPTURE:-/tmp/auq_stdin_capture.log}"
: > "$CAP"
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"header":"Goal","question":"What?","multiSelect":false,"options":[{"label":"A","description":"first"}]}]}}]}}'
echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Answer questions?","is_error":true}]}}'
echo '{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":1,"result":""}'
cat > "$CAP"        # capture whatever the harness writes to our stdin (prompt + interrupt) until it closes stdin
