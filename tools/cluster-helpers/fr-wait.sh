#!/usr/bin/env bash
# Waits until none of the given job ids is queued or running, then prints
# their sacct state. Never prompts. Usage: fr-wait.sh <max_seconds> <id> [id...]
#
# Reads sacct, never squeue. The old version counted squeue lines, and squeue
# prints nothing both when the jobs have left the queue and when it fails
# (slurmctld busy, a purged id): an outage looked like "all done". Here a job
# is finished only when sacct names it in a terminal state, and every id must
# appear in the reply, so a short or empty reply is a failed poll.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
MAX="${1:?max-seconds}"; shift
IDS="$(IFS=,; echo "$*")"; NIDS=$#
t0=$(date +%s); fails=0
while :; do
  [ -S "$SOCK" ] || { echo "CONTROL SOCKET GONE"; exit 3; }
  # One line per id: -X drops steps; het components (id+N) collapse to id.
  rows=$(timeout 60 ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
         "sacct -X -n -P -j $IDS -o JobID,State" 2>/dev/null \
         | awk -F'|' '{split($1,a,"+"); s=$2; sub(/ .*/,"",s); st[a[1]]=(st[a[1]]==""||s~/PENDING|RUNNING|REQUEUED|SUSPENDED|COMPLETING|CONFIGURING|RESIZING/)?s:st[a[1]]} END{for(j in st) print j, st[j]}')
  seen=$(printf '%s\n' "$rows" | grep -c .)
  if [ "$seen" -lt "$NIDS" ]; then
    fails=$((fails + 1)); echo "poll failed: sacct named $seen of $NIDS jobs ($fails/3)"
    [ "$fails" -ge 3 ] && { echo "GIVING UP"; exit 3; }
  else
    fails=0
    live=$(printf '%s\n' "$rows" | grep -cE ' (PENDING|RUNNING|REQUEUED|SUSPENDED|COMPLETING|CONFIGURING|RESIZING)$')
    [ "$live" -eq 0 ] && break
  fi
  [ $(( $(date +%s) - t0 )) -ge "$MAX" ] && { echo "TIMEOUT after ${MAX}s"; break; }
  sleep 120
done
timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" "sacct -X -n -j $IDS -o JobID,JobName,State,ExitCode,Start,Elapsed,NodeList"
