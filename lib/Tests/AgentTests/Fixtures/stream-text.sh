#!/bin/bash
# Emits a streamed text content block (coalesced from deltas) plus a terminal result event,
# so the StreamProjector lands a content_block row and finalizes the turn. Exits cleanly.
echo '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}'
echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}}'
echo '{"type":"stream_event","event":{"type":"content_block_stop","index":0}}'
echo '{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"total_cost_usd":0.25,"result":"Hello, world"}'
