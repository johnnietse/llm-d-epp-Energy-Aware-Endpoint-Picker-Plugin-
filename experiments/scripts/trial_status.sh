#!/usr/bin/env bash
# Reports progress of the Stage 2 trials named as arguments.
#
# Exists as a file pushed with scp and run by path, rather than piped to
# "ssh ... bash -s" or embedded in a quoted ssh command string. Both of those
# failed in this session: the stdin-fed form silently delivered an empty script
# (bash -xs produced no trace at all), and the inline-quoted form mangled
# nested quotes badly enough that squeue was not even found. A file on the far
# side has no quoting layer to get wrong.
set -u
cd "$HOME/energy-epp/scripts" || exit 1

for J in "$@"; do
  L="$(ls -t stage2-real-"$J"-*.out 2>/dev/null | head -1)"
  state="$(squeue -h -j "$J" -o '%T %M %N' 2>/dev/null)"
  [ -n "$state" ] || state="$(sacct -n -X -j "$J" --format=State,Elapsed,NodeList -P 2>/dev/null | head -1)"
  echo "=== $J  $state"
  if [ -z "$L" ]; then
    echo "  no log yet"
    continue
  fi
  echo "  log: $L  cells=$(grep -c 'J/req' "$L" 2>/dev/null)"
  grep -E 'hard deadline|ready: |PEAK_RPS|load levels|curve for Quadro|seed=|FATAL' "$L" 2>/dev/null | sed 's/^/  /' | head -8
  echo "  --- last 2 lines ---"
  tail -2 "$L" | sed 's/^/  /'
  echo "  client_limited=$(grep -c 'CLIENT LIMITED' "$L" 2>/dev/null) out_of_range=$(grep -c 'CURVE OUT OF RANGE' "$L" 2>/dev/null)"
done
