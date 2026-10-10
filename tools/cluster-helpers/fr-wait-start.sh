#!/usr/bin/env bash
# Waits up to $2 seconds for job $1 to leave PENDING; prints its state and
# start time.
#
#   bash fr-wait-start.sh <jobid> <max-seconds>
#
# Reads sacct, never squeue. squeue forgets a job once it finishes, and the old
# version took "not in squeue" for "not started": on 2026-10-10 it was armed
# after job 12330546 had already run and finished, so it would have waited out
# its whole timeout and never reported. sacct keeps the job, so a job that
# started (or even finished) before this script was armed is reported at once,
# with a note saying so. An empty sacct reply is a failed poll, not a state.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"; HOST="hpc6081@login.cac.queensu.ca"
J="${1:?jobid}"; MAX="${2:?max-seconds}"
[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
armed=$(date +%s); fails=0
while :; do
  # -X: the allocation line only. For a heterogeneous job that is one line per
  # component (id+0, id+1); the first is enough to tell PENDING from started.
  row=$(timeout 60 ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
        "sacct -X -n -P -j $J -o State,Start,NodeList" 2>/dev/null | head -1)
  state="${row%%|*}"; state="${state%% *}"     # "CANCELLED by 123" -> CANCELLED
  if [ -z "$state" ]; then
    fails=$((fails + 1)); echo "poll failed ($fails/3)"
    [ "$fails" -ge 3 ] && { echo "GIVING UP: no sacct reply for job $J"; exit 3; }
  else
    fails=0
    if [ "$state" != PENDING ]; then
      start=$(echo "$row" | cut -d'|' -f2); nodes=$(echo "$row" | cut -d'|' -f3)
      s_epoch=$(date -d "$start" +%s 2>/dev/null || echo "$armed")
      note=""; [ "$s_epoch" -lt "$armed" ] && note="  (started BEFORE this watcher was armed)"
      echo "job $J: $state, started $start on $nodes$note"
      exit 0
    fi
  fi
  [ $(( $(date +%s) - armed )) -ge "$MAX" ] && { echo "STILL PENDING after $MAX s"; exit 1; }
  sleep 30
done
