#!/usr/bin/env bash
# Runs the node-local scratch probe. This decides whether the frnt155 wedge can
# be eliminated or only bounded.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
    "$SRC/probe_local_scratch.sbatch" "$HOST:energy-epp/scripts/" || exit 1

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1
J=$(sbatch --parsable --export=ALL probe_local_scratch.sbatch) || exit 1
echo "scratch probe: $J"
for i in $(seq 1 70); do
  [ -z "$(squeue -h -j "$J" 2>/dev/null)" ] && break
  sleep 10
done
sacct -n -X -j "$J" --format=State,Elapsed,ExitCode,NodeList -P
echo "--------------------------------------------"
cat "scratch-probe-$J.out" 2>/dev/null || echo "no log"
REMOTE
