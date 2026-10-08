#!/usr/bin/env bash
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"
[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$SRC/probe_arch_list.sbatch" "$HOST:energy-epp/scripts/" || exit 1
ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1
J=$(sbatch --parsable --export=ALL probe_arch_list.sbatch) || exit 1
echo "submitted $J"
for i in $(seq 1 50); do
  [ -z "$(squeue -h -j "$J" 2>/dev/null)" ] && break
  sleep 10
done
sacct -n -X -j "$J" --format=State,Elapsed,ExitCode,NodeList -P
echo "--------------------------------------------"
cat "arch-probe-$J.out" 2>/dev/null || echo "no log"
REMOTE
