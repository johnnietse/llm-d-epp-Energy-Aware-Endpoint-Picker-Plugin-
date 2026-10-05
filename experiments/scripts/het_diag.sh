#!/usr/bin/env bash
# Diagnoses a het job whose servers did not all come up.
#   bash het_diag.sh <jobid>
set -u
J="${1:?usage: het_diag.sh <jobid>}"
R="$HOME/energy-epp/results/stage2het-$J"
L="$HOME/energy-epp/scripts/stage2-het-$J.out"

echo "=== staging decisions (which directory did each node pick?) ==="
grep -E "MiB of weights staged|verifying|HF_HOME=|: OK$|MKDIR|COPY|THIN|FATAL" "$L" 2>/dev/null | sed 's/^/  /'

echo
echo "=== component inventory and fleet ==="
grep -E "component [0-9]:|balancing|fleet:" "$L" 2>/dev/null | sed 's/^/  /'

echo
echo "=== first real error in each server log that never came up ==="
for f in "$R"/vllm-*.log; do
  [ -f "$f" ] || continue
  # Did this one ever serve a health check?
  if grep -q '"GET /health HTTP/1.1" 200' "$f" 2>/dev/null; then
    echo "  OK   $(basename "$f") - served health checks"
    continue
  fi
  echo "  DOWN $(basename "$f") ($(wc -l < "$f") lines)"
  grep -nE "Error|error|No such file|not found|Traceback|Exception|CUDA|OSError|ValueError|RuntimeError|does not exist|Permission" \
    "$f" 2>/dev/null | grep -v "GET /health" | head -6 | sed 's/^/       /'
  echo "       --- first 6 lines ---"
  head -6 "$f" 2>/dev/null | cut -c1-120 | sed 's/^/       /'
done

echo
echo "=== what HF_HOME did the servers actually get, and does it exist per node? ==="
grep -m1 "HF_HOME now" "$L" 2>/dev/null | sed 's/^/  /'
for n in $(grep -oE "component [0-9]: host=[^ ]+" "$L" 2>/dev/null | awk '{print $3}' | cut -d= -f2); do
  echo "  checking $n:"
  srun_out="$(timeout 30 srun --nodelist="$n" --nodes=1 --ntasks=1 --overlap \
    --jobid="$J" bash -c 'ls -d "$SLURM_TMPDIR"/hfstage 2>/dev/null || echo ABSENT' 2>/dev/null | tail -1)"
  echo "    \$SLURM_TMPDIR/hfstage -> ${srun_out:-unknown}"
done
