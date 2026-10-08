#!/usr/bin/env bash
# Pushes and runs the clock-effect verification.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
for f in verify_clock_effect.sbatch clock_effect_bench.py; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1
J=$(sbatch --parsable --export=ALL verify_clock_effect.sbatch) || exit 1
echo "submitted $J"
for i in $(seq 1 100); do
  [ -z "$(squeue -h -j "$J" 2>/dev/null)" ] && break
  sleep 10
done
sacct -n -X -j "$J" --format=State,Elapsed,ExitCode,NodeList -P
echo "--------------------------------------------"
cat "clk-verify-$J.out" 2>/dev/null || echo "no log"
REMOTE
