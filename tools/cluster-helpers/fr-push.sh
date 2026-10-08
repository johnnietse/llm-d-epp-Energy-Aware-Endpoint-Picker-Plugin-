#!/usr/bin/env bash
# Submits the Stage 2 RE-RUN on FOUR GPUs, two trials in PARALLEL on different
# nodes.
#
# Why four and not eight. frnt155 is the only 8x rtx6000 node on the cluster,
# and it is wedged: job 12303653's vLLM processes stuck in uninterruptible GPFS
# I/O, so scancel left the job in COMPLETING for hours and Slurm cannot reap
# it. An 8-GPU rtx6000 run has nowhere else to go. There are ~85 idle 4-GPU
# rtx6000 nodes, so four endpoints is available now and lets the two trials run
# side by side instead of serialised behind one node.
#
# Nothing is lost by this. The 8-GPU run it would have reproduced (12303355)
# has a rejected verdict, so there is no result to stay comparable with. What
# matters is that routing is now grounded in a curve measured to concurrency
# 128, and four endpoints exercises every policy exactly as eight does.
#
# Load levels. The grounded curve gives 52.19 req/s per GPU at c=128, so four
# endpoints is ~209 req/s of capacity. p95 crosses the 2.0 s SLO between c=64
# (1.852 s) and c=96 (2.202 s), so feasible per-endpoint concurrency is about
# 78: 4 x 78 = 312 in flight, which at ~1.9 s service time is ~165 req/s. The
# sweep brackets that.
#
# Generator workers: 6, not 12. These nodes have 20 CPUs, not 32, and the
# generator shares them with four vLLM servers. Eight workers already delivered
# 259 req/s in calibration, so six covers 180 req/s with room to spare.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }

for f in policy_harness.py stage2_analyse.py stage2_real.sbatch; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1
python3 -c "import ast;ast.parse(open('policy_harness.py').read());print('harness syntax ok')" || exit 1
bash -n stage2_real.sbatch && echo "sbatch syntax ok" || exit 1

# Release the 8-GPU attempts; frnt155 is not coming back in useful time.
# Nothing to cancel this round.

export POLICIES="round_robin,least_loaded,slo_packing,energy_greedy,energy_consolidate"
export RATES="120,136,150,165,180"
export DURATION=60
export MAX_GPUS=4
export WORKERS=6

echo
echo "=== Stage 2 RE-RUN #2 on 4x rtx6000: energy-policy fallback fixed ==="
echo "policies: $POLICIES"
echo "rates:    $RATES req/s (brackets the ~165 req/s knee for 4 endpoints)"
echo "window:   ${DURATION}s per cell, $WORKERS generator workers"

export SEED=7
J1=$(sbatch --parsable --gres=gpu:rtx6000:4 --export=ALL stage2_real.sbatch) || exit 1
echo "trial 1 (seed 7):  $J1"

export SEED=11
J2=$(sbatch --parsable --gres=gpu:rtx6000:4 --export=ALL stage2_real.sbatch) || exit 1
echo "trial 2 (seed 11): $J2"

sleep 8
squeue -u "$(id -un)" -o '%.10i %.14j %.8T %.10M %.22R'
REMOTE
