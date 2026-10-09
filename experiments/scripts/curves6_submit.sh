#!/usr/bin/env bash
# Cluster-side. Submits the final Stage 1 curves for the Stage 5 amendment.
#
#   bash curves6_submit.sh       # via: bash fr-sync.sh run curves6_submit.sh
#
# Author decisions 2026-10-09, all before the data:
#   - TRIALS=6, so five usable trials per level after the warm-up trial is
#     dropped. That is Stage 1's standard; the 3-trial run (h1-12324871/2)
#     had only two usable and is kept as a record, not used.
#   - The A100 goes to 512 concurrent. At 256 it reached only 1.41 s p50
#     (h1-12324871), so a curve ending at 256 would still cap packing on the
#     mixed fleet below the 2.0 s SLO. 320/384/512 locate where it crosses.
#     The RTX 6000 crosses 2.0 s between 64 and 96, so 256 already covers it.
#
# Walltime is raised to 4.5 h: the 3-trial run spent ~28 s per cell beyond
# the 75 s window, so 16 levels x 6 trials on the A100 is ~2 h 45 m, too near
# the script's default 3 h.
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n h1_sweep.sbatch || { echo "h1_sweep.sbatch syntax error"; exit 1; }
export SECONDS_PER_LEVEL=75
export TRIALS=6

submit() {  # $1 label, $2 gres, $3 node, $4 levels
  J=$(LEVELS="$4" sbatch --parsable --gres="gpu:$2:1" -w "$3" --time=04:30:00 \
        --export=ALL h1_sweep.sbatch 2>&1) \
    || { echo "  $1: SUBMIT FAILED: $J"; return 1; }
  echo "  $1 on $3: job $J  levels=$4 trials=$TRIALS"
}
submit a100    a100    frnt154 "1,2,4,8,16,32,48,64,96,128,160,192,256,320,384,512"
submit rtx6000 rtx6000 frnt149 "1,2,4,8,16,32,48,64,96,128,160,192,256"
sleep 5
squeue -u "$(id -un)" -o '%.12i %.12j %.9T %.9M %.28R'
