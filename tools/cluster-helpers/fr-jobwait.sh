#!/usr/bin/env bash
# Waits for named Slurm job ids to leave the queue, then runs one cluster-side
# script with arguments and prints its output.
#
#   bash fr-jobwait.sh <max-seconds> "<jobid> [jobid...]" <script> [args...]
#
# Counts ids through het_status.sh's QUEUED_COUNT line, never by grepping
# human-readable output (the header-match bug that kept fr-hetwait.sh running
# to its deadline). A missing count is a failed poll, not zero.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
MAX="${1:?max-seconds}"; IDS="${2:?job ids}"; SCRIPT="${3:?script}"; shift 3
[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
deadline=$(( $(date +%s) + MAX )); fails=0
while :; do
  out="$(ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
         bash energy-epp/scripts/het_status.sh $IDS 2>&1)"
  left="$(printf '%s\n' "$out" | sed -n 's/^QUEUED_COUNT=//p' | head -1)"
  case "$left" in
    ''|*[!0-9]*) fails=$((fails + 1)); echo "poll failed ($fails/3)"
                 [ "$fails" -ge 3 ] && { echo "GIVING UP"; exit 3; } ;;
    0) break ;;
    *) fails=0; echo "--- $(date -u +%H:%M:%SZ): $left still queued or running" ;;
  esac
  [ "$(date +%s)" -ge "$deadline" ] && { echo "DEADLINE after ${MAX}s"; exit 4; }
  sleep 30
done
case "$SCRIPT" in
  *.py) ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" python3 "energy-epp/scripts/$SCRIPT" "$@" ;;
  *)    ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash "energy-epp/scripts/$SCRIPT" "$@" ;;
esac
