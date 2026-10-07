#!/usr/bin/env bash
# Cluster-side: submit one sbatch, wait for it, print its log.
#   bash run_sbatch_probe.sh <sbatch-name> <log-prefix> [extra sbatch args...]
set -u
cd "$HOME/energy-epp/scripts" || exit 1
NAME="$1"; PREFIX="$2"; shift 2
bash -n "$NAME" || { echo "FATAL: $NAME syntax"; exit 1; }
J=$(sbatch --parsable --export=ALL "$@" "$NAME" 2>&1) || { echo "SUBMIT FAILED: $J"; exit 1; }
JID="${J%%+*}"
echo "submitted $JID"
for i in $(seq 1 60); do
  [ -z "$(squeue -h -j "$JID" 2>/dev/null)" ] && break
  sleep 10
done
sacct -n -X -j "$JID" --format=State,Elapsed,ExitCode,NodeList -P
echo "--------------------------------------------"
cat "${PREFIX}-${JID}.out" 2>/dev/null || ls -1t "${PREFIX}"-*.out 2>/dev/null | head -2
