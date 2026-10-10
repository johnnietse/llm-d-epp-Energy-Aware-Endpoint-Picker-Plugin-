#!/usr/bin/env bash
# Cluster-side. Reference runs for validate_capacity.py (committed before
# this ran): round_robin and least_loaded on the one-type fleet (8x RTX 6000,
# frnt155) at 300 req/s, seeds 921-923, under the final router design (h = 0,
# open-loop curves, cap 256, random tie-break) - identical conditions to the
# v1 validation cell that failed.
#
#   bash capacity_ref_submit.sh     # via: bash fr-sync.sh run capacity_ref_submit.sh
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n stage2_real.sbatch || exit 1
python3 select_openloop_curves.py "$HOME/energy-epp" Qwen/Qwen2.5-1.5B-Instruct >/dev/null \
  || { echo "FATAL: no usable open-loop curves"; exit 1; }
export MODEL="Qwen/Qwen2.5-1.5B-Instruct"
export HEADROOMS="0" POLICIES="round_robin,least_loaded" RATES=300
export SLO=2.0 DURATION=60 WORKERS=16
export CURVE_SOURCE=openloop MAX_INFLIGHT=256 TIEBREAK=random
for SEED in 921 922 923; do
  export SEED
  J=$(sbatch --parsable --export=ALL --job-name=capref-real \
        -w frnt155 --nodes=1 --exclusive --mem=0 --gres=gpu:rtx6000:8 \
        stage2_real.sbatch 2>&1) || { echo "seed $SEED SUBMIT FAILED: $J"; exit 1; }
  echo "seed $SEED: job ${J%%+*}"
done
sleep 4
squeue -h -u "$(id -un)" -o '%.12i %.12j %.9T %.9M %.28R'
