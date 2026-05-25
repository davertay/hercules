#!/bin/bash
# Exits with non-zero status and stderr, simulating a harness failure.
echo "Fatal error: harness failed" >&2
exit 1
