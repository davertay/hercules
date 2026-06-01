#!/bin/bash
# Emits a malformed line and exits with non-zero status.
echo 'not valid json here'
echo "Fatal error: harness failed" >&2
exit 1
