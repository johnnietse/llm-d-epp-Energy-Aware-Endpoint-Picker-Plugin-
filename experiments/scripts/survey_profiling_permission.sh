#!/bin/bash
# How widespread is the profiling-permission inconsistency?
#
# DCGM's behaviour follows deterministically from RmProfilingAdminOnly, shown
# on frnt148 (0, all profiling fields readable) and frnt149 (1, all refused).
# So the cluster-wide picture only needs that bit per node, which a one-CPU
# one-minute job can read from /proc/driver/nvidia/params. No GPU allocation,
# no --exclusive, so these schedule immediately instead of waiting for a node
# to drain.
#
# Run on the login node. Writes a table to
# ~/energy-epp/instruments-probe/permission-survey.txt

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail

OUT_DIR="$HOME/energy-epp/instruments-probe"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/permission-survey.txt"
WORK="$OUT_DIR/survey"
mkdir -p "$WORK"

: > "$OUT"
echo "=== profiling-permission survey, $(date -Is) ===" | tee -a "$OUT"
echo "" | tee -a "$OUT"

# Which nodes actually have GPUs, and what kind?
echo "--- GPU nodes known to Slurm ---" | tee -a "$OUT"
sinfo -h -o '%n %G %t %f' 2>/dev/null | awk '$2 != "(null)" && $2 != ""' | sort | tee -a "$OUT"
echo "" | tee -a "$OUT"

NODES="$(sinfo -h -o '%n %G %t' 2>/dev/null \
  | awk '$2 != "(null)" && $2 != "" && ($3 == "idle" || $3 == "mix" || $3 == "alloc") {print $1}' \
  | sort -u)"

if [ -z "$NODES" ]; then
  echo "no GPU nodes reported as schedulable" | tee -a "$OUT"
  exit 0
fi

echo "--- submitting a 1-CPU reader to each node ---" | tee -a "$OUT"
for n in $NODES; do
  short="${n%%.*}"
  sbatch --job-name="perm-$short" \
         --account=def-hpcg1971_gpu \
         -w "$short" \
         --cpus-per-task=1 --mem=1G -t 00:02:00 \
         --output="$WORK/perm-$short.out" \
         --wrap "printf '%s|%s|%s|%s\n' \"\$(hostname -s)\" \
                 \"\$(grep -oE 'RmProfilingAdminOnly: [0-9]+' /proc/driver/nvidia/params 2>/dev/null | awk '{print \$2}' || echo NA)\" \
                 \"\$(uname -r)\" \
                 \"\$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')\"" \
         >> "$OUT" 2>&1
done
echo "" | tee -a "$OUT"

echo "--- waiting for the readers ---" | tee -a "$OUT"
for i in $(seq 1 60); do
  left="$(squeue -h -u "$(id -un)" -o '%j' 2>/dev/null | grep -c '^perm-' || true)"
  [ "$left" -eq 0 ] && { echo "all readers finished after $i polls" | tee -a "$OUT"; break; }
  sleep 10
done
echo "" | tee -a "$OUT"

echo "--- result: node | RmProfilingAdminOnly | kernel | gpu,driver ---" | tee -a "$OUT"
cat "$WORK"/perm-*.out 2>/dev/null | grep -E '^frnt' | sort | tee -a "$OUT"
echo "" | tee -a "$OUT"

echo "--- tally ---" | tee -a "$OUT"
cat "$WORK"/perm-*.out 2>/dev/null | grep -E '^frnt' \
  | awk -F'|' '{print $2}' | sort | uniq -c \
  | awk '{printf "  RmProfilingAdminOnly=%s on %s node(s)\n", $2, $1}' | tee -a "$OUT"
echo "" | tee -a "$OUT"
echo "--- does it track the kernel build? ---" | tee -a "$OUT"
cat "$WORK"/perm-*.out 2>/dev/null | grep -E '^frnt' \
  | awk -F'|' '{print "  " $2 "  " $3}' | sort | uniq -c | tee -a "$OUT"

echo "" | tee -a "$OUT"
echo "=== done: $OUT ===" | tee -a "$OUT"
