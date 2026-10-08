#!/usr/bin/env bash
# Second exec wrapper, so a quick query can run while fr-cmd.sh is in use by a
# long-running background job.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
exec ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s < /mnt/c/Users/Johnnie/fr-cmd2.sh
