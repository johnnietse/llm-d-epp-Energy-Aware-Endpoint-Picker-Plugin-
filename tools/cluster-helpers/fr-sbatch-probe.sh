#!/usr/bin/env bash
# Pushes an sbatch from experiments/scripts, submits it, waits, prints its log.
#   bash fr-sbatch-probe.sh <sbatch-name> <log-prefix> [extra sbatch args...]
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
NAME="$1"; PREFIX="$2"; shift 2

scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
    "$SRC/$NAME" "$HOST:energy-epp/scripts/" || exit 1

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
  bash energy-epp/scripts/run_sbatch_probe.sh "$NAME" "$PREFIX" "$@"
