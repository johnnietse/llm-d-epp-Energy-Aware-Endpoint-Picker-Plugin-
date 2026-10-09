#!/usr/bin/env bash
# Cluster-side. A short smoke run of openloop_curve.sbatch before the full
# curves: 2 rates, 2 trials, 20 s cells, on the A100 node. It checks that vLLM
# starts with the pinned limits, the harness runs one-endpoint open loop,
# idle power is read, and openloop_build.py writes curve.csv. Its numbers are
# not used for anything.
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n openloop_curve.sbatch || exit 1
J=$(RATES=4,37 TRIALS=2 DURATION=20 WORKERS=6 SEED=799 sbatch --parsable \
      --gres=gpu:a100:1 -w frnt154 --time=00:40:00 --job-name=olc-smoke \
      --export=ALL openloop_curve.sbatch 2>&1) || { echo "SUBMIT FAILED: $J"; exit 1; }
echo "smoke job $J"
sleep 4
squeue -u "$(id -un)" -o '%.12i %.12j %.9T %.9M %.28R'
