#!/usr/bin/env bash
# Watches one heterogeneous Stage 2 job. Takes the job id as its argument.
#
#   bash het_watch.sh <jobid> [max_minutes]
#
# Separate from submission so its wait duration is the only thing a caller's
# timeout has to accommodate. The combined version was killed at exit 143
# because an outer 590 s timeout met an internal 25-minute loop.
#
# max_minutes defaults to 20, which covers startup plus a few cells. Call it
# again to keep watching; it is stateless.
set -u
J="${1:?usage: het_watch.sh <jobid> [max_minutes]}"
MAXMIN="${2:-20}"
DEADLINE=$(( $(date +%s) + MAXMIN * 60 ))
cd "$HOME/energy-epp/scripts" || exit 1

LOG=""
prev=""
stuck=0
reported_ready=0

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  [ -z "$LOG" ] && LOG="$(ls -t stage2-het-"$J".out 2>/dev/null | head -1)"
  state="$(squeue -h -j "$J" -o '%T' 2>/dev/null | head -1)"

  if [ -n "$LOG" ]; then
    if grep -q "FATAL" "$LOG" 2>/dev/null; then
      echo "=== ABORTED BY ITS OWN GUARD (this is the good outcome) ==="
      grep -B 4 -A 14 "FATAL" "$LOG" | head -24
      exit 1
    fi
    if [ "$reported_ready" -eq 0 ] && grep -q "^ready: " "$LOG" 2>/dev/null; then
      reported_ready=1
      echo "=== STARTUP COMPLETE ==="
      grep -E "component [0-9]:|balancing|fleet:|staged |HF_HOME now|skew bound|ready: |SLO =|PEAK_RPS|load levels|curve for" \
        "$LOG" | sed 's/^/  /' | head -24
      echo
    fi
    if [ "$reported_ready" -eq 1 ]; then
      # cat into grep: grep -c on a path that globs prints one count per
      # file, which is what garbled this line's output on job 12305215.
      cells="$(grep -a 'J/req' "$LOG" 2>/dev/null | wc -l | tr -d ' ')"
      cl="$(grep -a 'CLIENT LIMITED' "$LOG" 2>/dev/null | wc -l | tr -d ' ')"
      ug="$(grep -a 'UNGROUNDED ROUTING' "$LOG" 2>/dev/null | wc -l | tr -d ' ')"
      echo "  cells=$cells client_limited=$cl ungrounded=$ug state=${state:-done}"
    fi
  fi

  if [ -z "$state" ]; then
    echo
    echo "=== JOB LEFT THE QUEUE ==="
    sacct -n -X -j "$J" --format=JobID,State,Elapsed,ExitCode,NodeList -P
    [ -n "$LOG" ] && tail -6 "$LOG" | sed 's/^/  /'
    exit 0
  fi

  # The frnt155 signature: not ready, and no server log growing.
  if [ "$reported_ready" -eq 0 ]; then
    R="$HOME/energy-epp/results/stage2het-$J"
    now="$(stat -c%s "$R"/vllm-*.log 2>/dev/null | tr '\n' ' ')"
    if [ -n "$now" ] && [ "$now" = "$prev" ]; then
      stuck=$((stuck + 1))
      if [ "$stuck" -eq 6 ]; then
        echo "*** WEDGE SIGNATURE: ~90 s with no server log growth, not ready."
        echo "    Node-local staging should have prevented this. Last lines:"
        for f in "$R"/vllm-*.log; do
          printf '      %s: ' "$(basename "$f")"; tail -1 "$f" | cut -c1-110
        done
      fi
    else
      stuck=0
    fi
    prev="$now"
  fi
  sleep 15
done

echo
echo "watch window of ${MAXMIN} min elapsed; job $J still ${state:-unknown}"
echo "run again to keep watching: bash het_watch.sh $J"
