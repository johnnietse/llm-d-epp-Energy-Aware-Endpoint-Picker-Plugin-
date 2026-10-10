#!/usr/bin/env bash
# Waits up to $2 seconds for job $1 to leave PENDING; prints its state.
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"; HOST="hpc6081@login.cac.queensu.ca"
t0=$(date +%s)
until st=$(timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" "squeue -h -j $1 -o '%T %R' | head -1") && [ -n "$st" ] && [ "${st%% *}" != "PENDING" ]; do
  [ $(( $(date +%s) - t0 )) -ge "$2" ] && { echo "STILL PENDING after $2 s: $st"; exit 1; }
  sleep 30
done
echo "job $1: $st"
