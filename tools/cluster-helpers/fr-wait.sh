#!/usr/bin/env bash
# Waits until none of the given job ids is queued or running, then prints
# their sacct state. Never prompts. Usage: frwait.sh <max_seconds> <id> [id...]
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
MAX="$1"; shift
IDS="$(IFS=,; echo "$*")"
t0=$(date +%s)
while :; do
  [ -S "$SOCK" ] || { echo "CONTROL SOCKET GONE"; exit 3; }
  n=$(timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" "squeue -h -j $IDS 2>/dev/null | wc -l")
  [ "${n:-1}" = "0" ] && break
  [ $(( $(date +%s) - t0 )) -ge "$MAX" ] && { echo "TIMEOUT after ${MAX}s, $n still queued"; break; }
  sleep 120
done
timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" "sacct -X -n -j $IDS -o JobID,JobName,State,ExitCode,Elapsed,NodeList"
