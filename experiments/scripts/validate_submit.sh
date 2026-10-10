#!/usr/bin/env bash
# Cluster-side. Submits the h = 0 validation (validate_h0.py, committed
# before this ran): seeds 921-923 on each fleet, the full Stage 5 load
# ladders, final router design (open-loop curves, cap 256, h = 0, random
# tie-break). No dependency: the curves olc-12325349/50 already exist.
#
#   bash validate_submit.sh      # via: bash fr-sync.sh run validate_submit.sh
set -u
cd "$HOME/energy-epp/scripts" || exit 1
for f in stage2_real.sbatch stage2_het.sbatch; do
  bash -n "$f" || { echo "FATAL: $f syntax"; exit 1; }
done
python3 -c "import ast;ast.parse(open('policy_harness.py').read())" || exit 1
grep -q -- '--tiebreak' stage2_het.sbatch && grep -q -- '--tiebreak' stage2_real.sbatch \
  || { echo "FATAL: batch scripts do not pass --tiebreak"; exit 1; }
python3 select_openloop_curves.py "$HOME/energy-epp" Qwen/Qwen2.5-1.5B-Instruct >/dev/null \
  || { echo "FATAL: no usable open-loop curves"; exit 1; }

export MODEL="Qwen/Qwen2.5-1.5B-Instruct"
export HEADROOMS="0"
export POLICIES="slo_packing,energy_greedy,energy_consolidate"
export SLO=2.0 DURATION=60 WORKERS=16 MAX_GPUS_PER_NODE=4
export CURVE_SOURCE=openloop MAX_INFLIGHT=256 TIEBREAK=random

for SEED in 921 922 923; do
  export SEED
  J1=$(RATES=100,150,200,250,300 sbatch --parsable --export=ALL --job-name=valid-real \
         -w frnt155 --nodes=1 --exclusive --mem=0 --gres=gpu:rtx6000:8 \
         stage2_real.sbatch 2>&1) || { echo "homog seed $SEED SUBMIT FAILED: $J1"; exit 1; }
  J2=$(RATES=200,300,400,500,600 sbatch --parsable --export=ALL --job-name=valid-het \
         --gres=gpu:a100:4    -w frnt154 --nodes=1 --exclusive --mem=0 \
       : --gres=gpu:rtx6000:4 -w frnt149 --nodes=1 --exclusive --mem=0 \
         stage2_het.sbatch 2>&1) || { echo "mixed seed $SEED SUBMIT FAILED: $J2"; exit 1; }
  echo "seed $SEED: homogeneous job ${J1%%+*}, mixed job ${J2%%+*}"
done
sleep 4
squeue -h -u "$(id -un)" -o '%.12i %.12j %.9T %.9M %.28R'
