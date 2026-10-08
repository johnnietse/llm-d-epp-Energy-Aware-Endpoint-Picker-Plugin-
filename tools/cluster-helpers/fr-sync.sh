#!/usr/bin/env bash
# Syncs experiments/scripts to the cluster, then optionally runs one script there.
#
#   bash fr-sync.sh                      # push everything
#   bash fr-sync.sh run <script> [args]  # push everything, then run that script
#
# A file, not an inline "wsl.exe -- bash -c '...'", because that form corrupts
# multi-line arguments: every newline becomes two double-quote characters, so
# variable assignments merge into the following line and read back empty. It has
# now produced four separate failures in this project, the latest being
# "no argument after keyword controlpath" from an empty $SOCK. Plan section 3.4
# lists it as a banned pattern; this script is how to avoid needing it.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }

n=0
for f in "$SRC"/*.py "$SRC"/*.sh "$SRC"/*.sbatch; do
  [ -f "$f" ] || continue
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
      "$f" "$HOST:energy-epp/scripts/" >/dev/null || exit 1
  n=$((n + 1))
done
echo "synced $n script(s)"

if [ "${1:-}" = "run" ]; then
  shift
  NAME="${1:?usage: fr-sync.sh run <script> [args]}"; shift
  case "$NAME" in
    *.py) ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
            python3 "energy-epp/scripts/$NAME" "$@" ;;
    *)    ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
            bash "energy-epp/scripts/$NAME" "$@" ;;
  esac
fi
