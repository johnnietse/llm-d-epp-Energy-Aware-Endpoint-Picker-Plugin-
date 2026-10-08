#!/usr/bin/env bash
# Waits until no stage2-het job is left in the queue, then prints the final
# status and the gate verdict for every completed run.
#
#   bash fr-hetwait.sh <max-seconds> <kind:jobid> [kind:jobid...]
#
# kind is "het" or "real". het jobs are reported with het_final.sh; real jobs
# (the homogeneous control) with real_status.sh, because het_final.sh only knows
# the stage2het-* layout and would report an empty directory for a control run.
#
# het_final.sh takes a job id (`J="${1:?jobid}"`) and reports one run, so the
# ids must be passed through; calling it bare just prints "jobid" and exits.
#
# Runs detached, so its own duration is the only bound that matters - there is
# no outer `timeout` to kill it at 590 s the way exit 143 killed the old
# combined submit-and-watch script. Polls over the shared control socket; if
# that socket dies, BatchMode makes ssh fail fast instead of hanging at an
# invisible password prompt, and this loop reports why it stopped rather than
# claiming the jobs finished.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
MAX="${1:-7200}"; shift || true
SPECS="$*"
[ -n "$SPECS" ] || { echo "usage: fr-hetwait.sh <max-seconds> <kind:jobid>..." >&2; exit 2; }
IDS=""
for spec in $SPECS; do
  case "$spec" in
    het:[0-9]*|real:[0-9]*) IDS="$IDS ${spec#*:}" ;;
    *) echo "bad job spec '$spec'; use het:<id> or real:<id>" >&2; exit 2 ;;
  esac
done
INTERVAL=60

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }

deadline=$(( $(date +%s) + MAX ))
fails=0
while :; do
  if ! out="$(ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
                 bash energy-epp/scripts/het_status.sh $IDS 2>&1)"; then
    fails=$((fails + 1))
    echo "poll failed ($fails/3) at $(date -u +%H:%M:%SZ)"
    [ "$fails" -ge 3 ] && { echo "GIVING UP: control socket is gone."; exit 3; }
    sleep "$INTERVAL"
    continue
  fi
  fails=0

  # Count the named job ids, not lines of human output. The old form grepped
  # for "stage2-het", which also matched the "=== recent stage2-het jobs ==="
  # header, so it never reached zero and every wait ran to its deadline.
  left="$(printf '%s\n' "$out" | sed -n 's/^QUEUED_COUNT=//p' | head -1)"
  case "$left" in
    ''|*[!0-9]*)
      echo "poll returned no QUEUED_COUNT line; treating as a failed poll"
      fails=$((fails + 1))
      [ "$fails" -ge 3 ] && { echo "GIVING UP: status output unparseable."; exit 3; }
      sleep "$INTERVAL"
      continue ;;
  esac
  echo "--- $(date -u +%H:%M:%SZ): $left of the named job(s) still queued or running"
  if [ "$left" -eq 0 ]; then
    printf '%s\n' "$out"
    echo
    echo "=== all trials off the queue; collecting verdicts ==="
    for spec in $SPECS; do
      kind="${spec%%:*}"; j="${spec#*:}"
      echo
      echo "################ $kind job $j ################"
      if [ "$kind" = het ]; then
        ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
          bash energy-epp/scripts/het_final.sh "$j" 2>&1
      else
        ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
          bash energy-epp/scripts/real_status.sh 2>&1
        ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
          python3 energy-epp/scripts/compare_runs.py \
          "/global/home/hpc6081/energy-epp/results/stage2-$j" 2>&1
      fi
    done
    exit 0
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "DEADLINE: ${MAX}s elapsed and jobs are still queued or running."
    printf '%s\n' "$out"
    exit 4
  fi
  sleep "$INTERVAL"
done
