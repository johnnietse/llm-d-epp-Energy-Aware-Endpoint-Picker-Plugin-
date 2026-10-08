#!/usr/bin/env bash
# 1. Extend the RTX 6000 curve to concurrency 256, so the deep-overload load
#    levels can be routed on measurement instead of a fallback. At 180 req/s on
#    four endpoints the measured in-flight count reaches ~121 per endpoint and
#    unevenness pushes many picks past the c=128 ceiling: 96.8% of picks had no
#    grounded option, so those cells measured the fallback, not the policy.
# 2. Re-run Stage 2 at five levels that all sit INSIDE the currently measured
#    range (110-150 req/s), which is where the knee is: attainment runs 100% to
#    40% across it. This yields a gated verdict now rather than after the
#    longer curve lands.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"
[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1

export LEVELS="1,2,4,8,16,32,48,64,96,128,160,192,256"
export SECONDS_PER_LEVEL=75
export TRIALS=2
JC=$(sbatch --parsable --gres=gpu:rtx6000:1 --export=ALL h1_sweep.sbatch) || exit 1
echo "RTX 6000 curve to c=256: job $JC"
unset LEVELS SECONDS_PER_LEVEL TRIALS

export POLICIES="round_robin,least_loaded,slo_packing,energy_greedy,energy_consolidate"
export RATES="110,120,130,140,150"
export DURATION=60
export MAX_GPUS=4
export WORKERS=6
export SEED=7
J1=$(sbatch --parsable --gres=gpu:rtx6000:4 --export=ALL stage2_real.sbatch) || exit 1
echo "Stage 2 grounded-range trial 1 (seed 7):  $J1"
export SEED=11
J2=$(sbatch --parsable --gres=gpu:rtx6000:4 --export=ALL stage2_real.sbatch) || exit 1
echo "Stage 2 grounded-range trial 2 (seed 11): $J2"
echo "rates: $RATES req/s (all within the measured c<=128 range)"
sleep 6
squeue -u "$(id -un)" -o '%.10i %.12j %.9T %.10M %.18R'
REMOTE
