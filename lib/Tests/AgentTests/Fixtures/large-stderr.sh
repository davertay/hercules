#!/bin/bash
# Writes 66 KB total to stderr: 1 KB of 'X' (to be dropped) then 64 KB of 'Y' (the tail).
head -c 1024 /dev/zero | tr '\0' 'X' >&2
head -c 65536 /dev/zero | tr '\0' 'Y' >&2
exit 1
