#!/usr/bin/env bash
# Cluster-side. Re-runs the two RTX 6000 max-num-seqs 64 curves of the vLLM
# batch-limit sensitivity study (jobs 12330596 and 12330598), whose
# pre-registered rows were left unresolved: their curves were cut at 1 req/s by
# a trial-level keep-up shortfall with normal latency (DATA-QUALITY.md).
#
#   bash sensitivity_rerun64_submit.sh
#
# Identical settings to sensitivity_submit.sh (frnt149, gpu:rtx6000:1, not
# exclusive, TRIALS=6, DURATION=60, WORKERS=6, SEED=730, the same rate grid),
# so the rerun is a repeat, not a new design. What differs is the harness: it
# now also records teardown_s, traffic_window_s and keepup_traffic, so the
# records can show directly whether worker teardown caused the shortfall.
# The original rows stay as recorded; the rerun is reported beside them.
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n openloop_curve.sbatch || exit 1
grep -q "def apply_energy_window" policy_harness.py \
  || { echo "FATAL: policy_harness.py lacks the traffic-window fields"; exit 1; }
export TRIALS=6 DURATION=60 WORKERS=6 SEED=730
RTX_RATES="1,3,7,13,20,27,34,40,47,54,61,67,74,82,90"
for batched in 2048 8192; do
  J=$(MAX_NUM_SEQS=64 MAX_BATCHED=$batched RATES=$RTX_RATES sbatch --parsable \
        --gres="gpu:rtx6000:1" -w frnt149 --time=04:30:00 --job-name="sens-rerun-rtx6000-64-$batched" \
        --export=ALL openloop_curve.sbatch 2>&1) || { echo "SUBMIT FAILED: $J"; continue; }
  echo "rtx6000 seqs=64 batched=$batched: job $J"
done
