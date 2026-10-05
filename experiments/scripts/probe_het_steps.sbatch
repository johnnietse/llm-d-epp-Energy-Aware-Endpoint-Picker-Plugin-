#!/bin/bash
# Can a heterogeneous job run FOUR concurrent srun --overlap steps per
# component, which is what stage2_het.sbatch needs for 4+4 vLLM servers?
#
# The het preflight proved --overlap works with one step per component. The
# real job needs four per component, eight in total, each pinned to a different
# GPU. Slurm limits concurrent steps in several ways (task counts, CPU binding,
# gres binding), and "it worked with one" is not evidence for eight. This is
# the same assumption shape that has cost two jobs today, so it gets three
# minutes instead of a five-hour allocation.
#
# Submit exactly as the real job:
#   sbatch --gres=gpu:a100:4   --nodes=1 --exclusive --mem=0 \
#        : --gres=gpu:rtx6000:4 --nodes=1 --exclusive --mem=0 \
#          probe_het_steps.sbatch
#
# Each step reports its host and which GPU it can see, then holds for 20 s so
# concurrency is observable rather than inferred from sequential completions.
#SBATCH --job-name=het-steps
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --time=00:08:00
#SBATCH --output=%x-%j.out

set -uo pipefail
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null || true
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"
IMG="$HOME/energy-epp/images/vllm-v0.30.0.sif"
RUN="$HOME/energy-epp/results/hetsteps-$SLURM_JOB_ID"
mkdir -p "$RUN"

echo "job=$SLURM_JOB_ID het_size=${SLURM_HET_SIZE:-unset}"
[ "${SLURM_HET_SIZE:-0}" -ge 2 ] || { echo "FATAL: need >=2 components"; exit 1; }

declare -a HOSTS NG
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  HOSTS[$g]="$(srun --het-group="$g" --nodes=1 --ntasks=1 hostname 2>/dev/null | head -1)"
  NG[$g]="$(srun --het-group="$g" --nodes=1 --ntasks=1 \
            nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)"
  echo "  component $g: ${HOSTS[$g]} with ${NG[$g]} gpu(s)"
done

TOTAL=0
PIDS=()
START="$(date +%s)"
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  for ((i=0; i<${NG[$g]}; i++)); do
    # CUDA_VISIBLE_DEVICES is how the real job pins each server to one GPU, so
    # exercise the same mechanism: a step that cannot see its GPU would fail
    # here rather than after a model load.
    # Verified through the CUDA runtime, not nvidia-smi.
    #
    # The first version of this probe asked nvidia-smi for the uuid and
    # reported that pinning had failed, because all 12 steps named the same
    # device. That was the probe being wrong, not the pinning: nvidia-smi
    # ignores CUDA_VISIBLE_DEVICES by design - it is a CUDA runtime variable,
    # not a driver one - so "head -1" returned GPU 0's uuid every time whatever
    # was set. torch honours it, and torch is what vLLM uses, so torch is the
    # only check that answers the question actually being asked.
    srun --het-group="$g" --nodes=1 --ntasks=1 --overlap \
      env -u SSL_CERT_FILE CUDA_VISIBLE_DEVICES="$i" \
      "$APPTAINER" exec --nv "$IMG" python3 -c "
import os, socket, time, torch
n = torch.cuda.device_count()
nm = torch.cuda.get_device_name(0) if n else 'none'
uu = None
if n:
    try:
        uu = str(torch.cuda.get_device_properties(0).uuid)
    except Exception:
        uu = 'unavailable'
print('%s step g=$g i=$i CVD=%s torch_sees=%d dev0=%s uuid=%s'
      % (socket.gethostname().split('.')[0],
         os.environ.get('CUDA_VISIBLE_DEVICES'), n, nm, uu))
time.sleep(20)
" > "$RUN/step-g${g}-i${i}.out" 2>&1 &
    PIDS+=($!)
    TOTAL=$((TOTAL + 1))
  done
done
echo
echo "launched $TOTAL concurrent steps; waiting"

# While they are held, count how many are actually running at once.
sleep 8
CONC="$(squeue -h -s -j "$SLURM_JOB_ID" 2>/dev/null | wc -l)"
echo "concurrent job steps visible to squeue: $CONC"

rc=0
for pid in "${PIDS[@]}"; do wait "$pid" || rc=1; done
ELAPSED=$(( $(date +%s) - START ))
echo "all steps finished in ${ELAPSED}s (rc=$rc)"

echo
echo "=== what each step reported ==="
ok=0
for f in "$RUN"/step-*.out; do
  line="$(head -1 "$f" 2>/dev/null)"
  if [ -n "$line" ]; then echo "  $line"; ok=$((ok + 1))
  else echo "  $(basename "$f"): EMPTY"; fi
done

echo
echo "=== distinct GPU uuids seen (should equal $TOTAL if pinning worked) ==="
NUUID="$(cat "$RUN"/step-*.out 2>/dev/null | grep -oE 'uuid=[0-9a-fA-F-]{8,}' | sort -u | wc -l)"
echo "  distinct uuids: $NUUID"

echo
echo "=================================================="
FAIL=0
[ "$ok" -eq "$TOTAL" ] || { echo "FAIL: only $ok/$TOTAL steps produced output"; FAIL=1; }
[ "$rc" -eq 0 ] || { echo "FAIL: at least one step exited nonzero"; FAIL=1; }
# 20 s hold each: if Slurm serialised them the elapsed time would be ~20*TOTAL.
if [ "$ELAPSED" -gt $((20 + 10 * TOTAL)) ]; then
  echo "FAIL: ${ELAPSED}s elapsed suggests Slurm SERIALISED the steps rather"
  echo "      than running them concurrently. stage2_het.sbatch would then"
  echo "      start its servers one at a time and blow the readiness deadline."
  FAIL=1
fi
[ "$NUUID" -eq "$TOTAL" ] || {
  echo "WARN: $NUUID distinct uuids for $TOTAL steps - GPU pinning may not be"
  echo "      isolating devices the way the real job assumes."; }
if [ "$FAIL" -eq 0 ]; then
  echo "PASSED: $TOTAL concurrent --overlap steps across ${SLURM_HET_SIZE} components."
else
  echo "FAILED - do not submit stage2_het.sbatch until this passes."
fi
exit "$FAIL"
