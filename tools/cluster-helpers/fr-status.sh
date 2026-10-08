#!/usr/bin/env bash
# Pushes trial_status.sh and runs it by path on the cluster.
# File-by-path, not stdin or an inline quoted string: both of those failed
# silently in this session.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$SRC/trial_status.sh" "$HOST:energy-epp/scripts/" || exit 1
ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash energy-epp/scripts/trial_status.sh "$@"
