#!/usr/bin/env bash
# Cluster-side. Submits the 2026-10-09 headroom calibration pilot.
#
#   bash calib_submit.sh <a100_job>:<rtx_job>     (or CURVE_JOBS=... env)
#
# Two jobs, both held until BOTH matched curve jobs (curves256_submit.sh) have
# completed successfully, because the router must use those curves. Curve jobs
# are ordinary jobs, so afterok works for them. Heterogeneous jobs are never
# used as a dependency (plan N16).
#
#   homogeneous: 8x RTX 6000 on frnt155, rates 100,150
#   mixed:       4x A100 on frnt154 + 4x RTX 6000 on frnt149, rates 300,400
#   both:        HEADROOMS=0,0.1,0.2,0.3, the three packing policies, SLO 2.0,
#                seed 901 (disjoint from the Stage 2 pilot seeds and from the
#                Stage 5 seeds 501-516 / 601-606)
#
# The decision rule is headroom_calibrate.py, committed before this ran.
set -u
cd "$HOME/energy-epp/scripts" || exit 1
CURVE_JOBS="${CURVE_JOBS:-${1:?usage: calib_submit.sh <a100_job>:<rtx_job>}}"
case "$CURVE_JOBS" in
  *[!0-9:]*|:*|*:) echo "FATAL: CURVE_JOBS must look like 123:456"; exit 1 ;;
esac
for f in stage2_real.sbatch stage2_het.sbatch; do
  bash -n "$f" || { echo "FATAL: $f syntax"; exit 1; }
done
python3 -c "import ast;ast.parse(open('policy_harness.py').read())" \
  || { echo "FATAL: policy_harness.py syntax"; exit 1; }
grep -q -- '--headroom "\$h"' stage2_real.sbatch && grep -q -- '--headroom "\$h"' stage2_het.sbatch \
  || { echo "FATAL: batch scripts do not pass --headroom"; exit 1; }

export MODEL="Qwen/Qwen2.5-1.5B-Instruct"
export HEADROOMS="0,0.1,0.2,0.3"
export POLICIES="slo_packing,energy_greedy,energy_consolidate"
export SLO=2.0
export SEED=901
export DURATION=60
export WORKERS=16
DEP="--dependency=afterok:$CURVE_JOBS"
echo "headrooms=$HEADROOMS policies=$POLICIES slo=$SLO seed=$SEED dep=$CURVE_JOBS"

J1=$(RATES=100,150 sbatch --parsable --export=ALL $DEP --job-name=calib-real \
       -w frnt155 --nodes=1 --exclusive --mem=0 --gres=gpu:rtx6000:8 \
       stage2_real.sbatch 2>&1) || { echo "homog SUBMIT FAILED: $J1"; exit 1; }
echo "homogeneous calibration: job ${J1%%+*}"

export MAX_GPUS_PER_NODE=4
J2=$(RATES=300,400 sbatch --parsable --export=ALL $DEP --job-name=calib-het \
       --gres=gpu:a100:4    -w frnt154 --nodes=1 --exclusive --mem=0 \
     : --gres=gpu:rtx6000:4 -w frnt149 --nodes=1 --exclusive --mem=0 \
       stage2_het.sbatch 2>&1) || { echo "mixed SUBMIT FAILED: $J2"; exit 1; }
echo "mixed calibration: job ${J2%%+*}"
sleep 4
squeue -h -u "$(id -un)" -o '%.12i %.12j %.9T %.9M %.24R'
