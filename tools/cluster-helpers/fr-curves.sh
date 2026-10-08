#!/usr/bin/env bash
# Submits Stage 1 curve sweeps for the GPU types we do not yet have, to
# concurrency 128.
#
# Why now. The one finding that keeps pointing somewhere else is that on a
# HOMOGENEOUS fleet routing barely matters: the three load-balancing policies
# came within +-1% of each other on J/req at every load level, and plain
# round-robin beat every consolidating policy on SLO-goodput per joule. An
# energy-aware scorer can only earn its keep when replicas differ in energy
# profile, which needs a second GPU type.
#
# Prerequisite for that is a curve per type, measured over the concurrency
# range the policies actually drive. We have RTX 6000 to c=128 (job 12303358)
# and A30/L4 only to c=32. There is no A100 or RTX 8000 curve at all, and
# frnt154/190/191 (8x A100) and frnt156 (8x RTX 8000) are idle.
#
# These also satisfy the standing optional item for A100/RTX 8000 sweeps, and
# they run on different nodes from the Stage 2 trials so nothing contends.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$SRC/h1_sweep.sbatch" "$HOST:energy-epp/scripts/" || exit 1

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n h1_sweep.sbatch && echo "sbatch syntax ok" || exit 1

export LEVELS="1,2,4,8,16,32,48,64,96,128"
export SECONDS_PER_LEVEL=75
export TRIALS=2

echo
echo "=== Stage 1 curve sweeps to concurrency 128 ==="
echo "levels: $LEVELS"

for g in a100 rtx8000; do
  J=$(sbatch --parsable --gres=gpu:$g:1 --export=ALL h1_sweep.sbatch 2>&1) || {
    echo "  $g: SUBMIT FAILED: $J"; continue; }
  echo "  $g curve: job $J"
done

# A30 and L4 curves exist but stop at c=32, which is below where the policies
# drive them. Extend both as well.
for g in a30 L4; do
  J=$(sbatch --parsable --gres=gpu:$g:1 --export=ALL h1_sweep.sbatch 2>&1) || {
    echo "  $g: SUBMIT FAILED: $J"; continue; }
  echo "  $g curve: job $J"
done

sleep 6
squeue -u "$(id -un)" -o '%.10i %.12j %.8T %.10M %.22R'
REMOTE
