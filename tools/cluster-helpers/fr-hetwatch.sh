#!/usr/bin/env bash
# Watches a heterogeneous Stage 2 job. bash fr-hetwatch.sh <jobid> [minutes]
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"
[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
    "$SRC/het_watch.sh" "$HOST:energy-epp/scripts/" >/dev/null || exit 1
ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
  bash energy-epp/scripts/het_watch.sh "$@"
