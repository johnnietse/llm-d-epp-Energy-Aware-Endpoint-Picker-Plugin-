#!/usr/bin/env bash
# Cluster-side. Submits the 2026-10-09 matched Stage 1 curves: A100 and
# RTX 6000, same concurrency grid to 256, same trial count, pinned nodes.
#
#   bash curves256_submit.sh            # via: bash fr-sync.sh run curves256_submit.sh
#
# Why (audit 2026-10-09, plan 12.14d). The Stage 2 policies are capped by the
# edge of each type's measured curve: interp() returns None above the top
# level and the router treats that endpoint as full. The A100 curve in use
# (h1-12304125) stops at 128, where A100 latency is 0.88 s, so on the mixed
# fleet the packers were stopped by that measurement edge, not by the 2.0 s
# SLO. The RTX 6000 curve (h1-12304133) reaches 256, so on the homogeneous
# fleet they packed to the SLO itself. Two fleets, two different binding
# constraints: the "reversal" compared those, not fleet composition. Measuring
# both types to 256 makes the SLO the binding constraint on both.
#
# Both old curves were also TRIALS=2, and trial 1 is dropped as warm-up, so
# each rested on one trial. TRIALS=3 gives two usable trials per level.
#
# Nodes are pinned to the ones the earlier curves came from: frnt154 (A100)
# and frnt149 (RTX 6000), per plan section 4 and pre-registration D6.
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n h1_sweep.sbatch || { echo "h1_sweep.sbatch syntax error"; exit 1; }

export LEVELS="1,2,4,8,16,32,48,64,96,128,160,192,256"
export SECONDS_PER_LEVEL=75
export TRIALS=3
echo "levels=$LEVELS seconds=$SECONDS_PER_LEVEL trials=$TRIALS"

submit() {  # $1 label, $2 gres, $3 node
  J=$(sbatch --parsable --gres="gpu:$2:1" -w "$3" --export=ALL h1_sweep.sbatch 2>&1) \
    || { echo "  $1: SUBMIT FAILED: $J"; return 1; }
  echo "  $1 on $3: job $J"
}
submit a100    a100    frnt154
submit rtx6000 rtx6000 frnt149
sleep 5
squeue -u "$(id -un)" -o '%.10i %.12j %.8T %.10M %.22R'
