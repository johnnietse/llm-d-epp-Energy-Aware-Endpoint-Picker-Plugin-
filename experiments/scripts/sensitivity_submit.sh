#!/usr/bin/env bash
# Cluster-side. Submits the vLLM batch-limit sensitivity study
# (docs/plan/SENSITIVITY-VLLM-LIMITS.md, committed before this ran):
# max-num-seqs {64,128,256,512} x max-num-batched-tokens {2048,8192} x
# {A100 on frnt154, RTX 6000 on frnt149} = 16 open-loop curves, 6 trials.
#
#   bash sensitivity_submit.sh      # via: bash fr-sync.sh run sensitivity_submit.sh
#
# Jobs on one node run one after another (the node is taken --exclusive),
# both nodes in parallel. Each job's instruments.txt records its vllm_args,
# and select_openloop_curves.py only accepts a curve whose limits match the
# run that asks for it, so none of these can become a Stage 5 curve.
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n openloop_curve.sbatch || { echo "openloop_curve.sbatch syntax error"; exit 1; }
grep -q 'MAX_NUM_SEQS=${MAX_NUM_SEQS:-256}' openloop_curve.sbatch \
  || { echo "FATAL: openloop_curve.sbatch does not take MAX_NUM_SEQS"; exit 1; }
export TRIALS=6 DURATION=60 WORKERS=6 SEED=730
A100_RATES="4,9,18,37,55,73,92,110,128,147,165,183,202,220,240"
RTX_RATES="1,3,7,13,20,27,34,40,47,54,61,67,74,82,90"

for seqs in 64 128 256 512; do
  for batched in 2048 8192; do
    for gpu in a100 rtx6000; do
      if [ "$gpu" = a100 ]; then node=frnt154; rates=$A100_RATES; else node=frnt149; rates=$RTX_RATES; fi
      J=$(MAX_NUM_SEQS=$seqs MAX_BATCHED=$batched RATES=$rates sbatch --parsable \
            --gres="gpu:$gpu:1" -w "$node" --time=04:30:00 --job-name="sens-$gpu-$seqs-$batched" \
            --export=ALL openloop_curve.sbatch 2>&1) \
        || { echo "  $gpu $seqs/$batched: SUBMIT FAILED: $J"; continue; }
      echo "  $gpu on $node seqs=$seqs batched=$batched: job $J"
    done
  done
done
sleep 4
squeue -u "$(id -un)" -o '%.12i %.24j %.9T %.9M %.28R'
